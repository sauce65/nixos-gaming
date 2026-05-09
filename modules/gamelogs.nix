# gamelogs: per-game log capture harness.
#
# Provides three CLIs:
#   gamerun <game> -- <cmd...>   wrapper that captures stdout/stderr, mirrors
#                                 the game's internal logs, snapshots system
#                                 state, classifies crashes, and rotates runs.
#   gamelogs <subcommand> ...    list/show/cat/grep/dump runs.
#   gamewatch <game>             live-tail latest run via lnav.
#
# Per-game declarations live in `gamelogs.games.<name>`. Each game declares
# the launcher binary it wraps, internal log paths inside the prefix, and any
# extra env. The bellum module is the canonical example.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.gamelogs;

  # Merge default env with per-game extraEnv. extraEnv wins on conflicts.
  gameEnv = game: cfg.defaultEnv // game.extraEnv;

  # Build the runtime registry. Read by all three CLIs at /etc/gamelogs/registry.json.
  registryJson = pkgs.writeText "gamelogs-registry.json" (builtins.toJSON {
    inherit (cfg) retainRuns retainCrashes minFreeMb defaultEnv;
    games = mapAttrs
      (_: g: {
        inherit (g) wrapperOf engine internalPaths extraEnv crashHooks;
        env = gameEnv g;
      })
      cfg.games;
  });

  registryPath = "/etc/gamelogs/registry.json";

  gamerun = pkgs.writeShellApplication {
    name = "gamerun";
    runtimeInputs = with pkgs; [
      jq
      coreutils      # tail -F, cp, ln, mkdir, rm, df
      util-linux
      systemd        # systemd-run, systemctl, journalctl, coredumpctl
      findutils
      gnugrep
      gnused
      gawk
    ];
    text = ''
      # gamerun <game> [--bench] [--dump-shaders] -- <cmd> [args...]
      #
      # Wraps a game launch with comprehensive log capture into
      # ''${XDG_STATE_HOME:-$HOME/.local/state}/games/<game>/runs/<runid>/.
      #
      # stdout/stderr are captured via shell redirection inherited by the
      # transient systemd user scope, so the wrapper dying doesn't drop logs.

      REGISTRY="''${GAMELOGS_REGISTRY:-${registryPath}}"

      usage() {
        cat <<'EOF'
      Usage: gamerun <game> [--bench] [--dump-shaders] [--debug] [--record] -- <command> [args...]

      Flags:
        --bench          enable MangoHud frametime CSV (output_folder=<run>/mangohud)
        --dump-shaders   set VKD3D_SHADER_DUMP_PATH=<run>/shaders (large output)
        --debug          enable heavy diagnostics (PROTON_LOG=1, DXVK_LOG_LEVEL=debug,
                         VKD3D_DEBUG=info). Adds GBs of log output per hour — only
                         use for triage runs, not normal play.
        --record         enable obs-vkcapture by setting OBS_VKCAPTURE=1 and
                         OBS_VKCAPTURE_NAME=<game>. The Vulkan layer is loaded
                         implicitly inside the game; OBS Studio's "Game Capture"
                         (vkcapture-source) will pick the frames up.
      EOF
      }

      bench=0
      dump_shaders=0
      debug=0
      record=0
      game=""
      cmd=()

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --bench)         bench=1; shift ;;
          --dump-shaders)  dump_shaders=1; shift ;;
          --debug)         debug=1; shift ;;
          --record)        record=1; shift ;;
          -h|--help)       usage; exit 0 ;;
          --)              shift; cmd=("$@"); break ;;
          -*)              echo "Unknown flag: $1" >&2; usage >&2; exit 1 ;;
          *)
            if [[ -z "$game" ]]; then
              game="$1"; shift
            else
              echo "Unexpected positional: $1 (use -- before the command)" >&2
              exit 1
            fi
            ;;
        esac
      done

      if [[ -z "$game" || ''${#cmd[@]} -eq 0 ]]; then
        usage >&2; exit 1
      fi

      if [[ ! -r "$REGISTRY" ]]; then
        echo "Registry not readable: $REGISTRY" >&2
        exit 1
      fi

      if ! game_data=$(jq -e --arg g "$game" '.games[$g] // empty' < "$REGISTRY"); then
        echo "Game '$game' not declared in registry" >&2
        echo "Declared games:" >&2
        jq -r '.games | keys[]' < "$REGISTRY" >&2
        exit 1
      fi

      retain_runs=$(jq -r '.retainRuns'    < "$REGISTRY")
      retain_crashes=$(jq -r '.retainCrashes' < "$REGISTRY")
      min_free_mb=$(jq -r '.minFreeMb'    < "$REGISTRY")

      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/games"
      mkdir -p "$state_dir/$game/runs"

      free_mb=$(df -BM --output=avail "$state_dir" | tail -n1 | tr -dc '0-9')
      if [[ -z "$free_mb" ]] || (( free_mb < min_free_mb )); then
        echo "Insufficient disk space at $state_dir: ''${free_mb:-?}MB free, need ''${min_free_mb}MB" >&2
        exit 2
      fi

      runid="$(date +%Y%m%d-%H%M%S)-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      run_dir="$state_dir/$game/runs/$runid"
      mkdir -p "$run_dir"/{system,system/coredumps,dxvk,internal,snapshot}

      # Build env from registry.games.<game>.env.
      declare -A env_map
      while IFS=$'\t' read -r k v; do
        env_map["$k"]="$v"
      done < <(jq -r '.env | to_entries[] | "\(.key)\t\(.value)"' <<< "$game_data")

      # Absorb known caller-provided vars so per-game wrapper exports (e.g.
      # bellum.nix exporting WINEPREFIX/PROTONPATH/GAMEID) participate in
      # path expansion, env.txt, and the inner scope's environment.
      for k in WINEPREFIX PROTONPATH GAMEID WINEARCH STORE UMU_LOG STEAM_COMPAT_DATA_PATH; do
        if [[ -n "''${!k:-}" ]]; then
          env_map["$k"]="''${!k}"
        fi
      done

      # Override log-output paths to land inside the run dir.
      env_map[DXVK_LOG_PATH]="$run_dir/dxvk"
      env_map[VKD3D_LOG_FILE]="$run_dir/vkd3d.log"
      env_map[DXVK_NVAPI_LOG_PATH]="$run_dir"
      env_map[WINEDEBUGLOG]="$run_dir/wine.log"
      env_map[PROTON_LOG_DIR]="$run_dir"

      if (( bench )); then
        mkdir -p "$run_dir/mangohud"
        env_map[MANGOHUD]="1"
        env_map[MANGOHUD_CONFIG]="output_folder=$run_dir/mangohud,log_duration=600,log_interval=100,autostart_log=1"
      fi

      if (( dump_shaders )); then
        mkdir -p "$run_dir/shaders"
        env_map[VKD3D_SHADER_DUMP_PATH]="$run_dir/shaders"
      fi

      if (( debug )); then
        # Heavy diagnostics — Wine's full Proton-style debug output, plus
        # bumped DXVK/VKD3D verbosity. Easily 1+ GB/hour during gameplay.
        env_map[PROTON_LOG]="1"
        env_map[DXVK_LOG_LEVEL]="debug"
        env_map[VKD3D_DEBUG]="info"
        env_map[DXVK_NVAPI_LOG_LEVEL]="info"
      fi

      if (( record )); then
        # Trigger obs-vkcapture's implicit Vulkan layer (registered via
        # VK_LAYER_OBS_vkcapture_64.json with enable_environment OBS_VKCAPTURE=1).
        # OBS Studio's vkcapture-source picks up frames over a Unix socket.
        # The OpenGL hook (libobs_glcapture.so via LD_PRELOAD) is intentionally
        # NOT injected here — getting LD_PRELOAD to survive Wine's startup is
        # fragile. Vulkan/DX11/DX12 games (DXVK/VKD3D-Proton) cover ~all
        # Windows games launched through this harness.
        env_map[OBS_VKCAPTURE]="1"
        env_map[OBS_VKCAPTURE_NAME]="$game"
      fi

      # Pre-launch system snapshots.
      start_iso=$(date --iso-8601=seconds)
      start_epoch=$(date +%s)

      if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi -q > "$run_dir/system/nvidia-smi-start.txt" 2>&1 || true
      fi
      if [[ -r /proc/driver/nvidia/version ]]; then
        cp /proc/driver/nvidia/version "$run_dir/system/nvidia-version.txt" 2>/dev/null || true
      fi
      if [[ -n "''${env_map[PROTONPATH]:-}" && -e "''${env_map[PROTONPATH]}/version" ]]; then
        cp "''${env_map[PROTONPATH]}/version" "$run_dir/snapshot/proton-version" 2>/dev/null || true
      fi
      if [[ -d "$HOME/.cache/umu-protonfixes" ]]; then
        ls -la "$HOME/.cache/umu-protonfixes" > "$run_dir/snapshot/umu-protonfixes.txt" 2>/dev/null || true
      fi

      # env.txt — stable order, easy to diff between runs.
      {
        for k in "''${!env_map[@]}"; do
          printf '%s=%s\n' "$k" "''${env_map[$k]}"
        done
      } | sort > "$run_dir/env.txt"

      # cmdline.txt — one arg per line.
      printf '%s\n' "''${cmd[@]}" > "$run_dir/cmdline.txt"

      # Initial metadata.json.
      cmd_json=$(printf '%s\n' "''${cmd[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
      jq -n \
        --arg game "$game" \
        --arg runid "$runid" \
        --arg started "$start_iso" \
        --argjson cmd "$cmd_json" \
        --arg engine "$(jq -r '.engine' <<< "$game_data")" \
        '{ schema_version: 1, game: $game, runid: $runid, started: $started, command: $cmd, engine: $engine }' \
        > "$run_dir/metadata.json"

      # Atomic latest symlink.
      ln -sfn "$runid" "$state_dir/$game/runs/latest"

      # gcroot (best-effort): pin Proton path during the run.
      gcroot_link=""
      gcroot_dir="/nix/var/nix/gcroots/per-user/$USER"
      if [[ -d "$gcroot_dir" && -w "$gcroot_dir" && -n "''${env_map[PROTONPATH]:-}" ]]; then
        gcroot_link="$gcroot_dir/game-$game-$runid"
        ln -sfn "''${env_map[PROTONPATH]}" "$gcroot_link" 2>/dev/null || gcroot_link=""
      fi

      # Internal-path mirroring via `tail -F`. The earlier inotify+cp approach
      # only fired on close_write/moved_to/create, missing the typical UE5
      # case where the engine holds the log file open for the entire run and
      # writes via plain fwrite (no close until exit). It also would have
      # required full-file copies on every event — at hundreds of MBs/hour
      # that's hundreds of GBs of write traffic on ext4 (no reflink).
      #
      # `tail -F -n +0` streams the existing content + all appends, by name,
      # auto-retrying if the file doesn't exist yet and reopening on rotation.
      # Disk traffic equals the source's actual byte rate. Tracked PIDs are
      # the tail processes themselves, so finalize can kill them directly.
      # The final-pass cp at finalize gives an authoritative snapshot in case
      # tail missed bytes at the very start of the run.
      mapfile -t internal_paths < <(jq -r '.internalPaths[]?' <<< "$game_data")
      mirror_pids=()
      for raw in "''${internal_paths[@]}"; do
        expanded="''${raw//\$WINEPREFIX/''${env_map[WINEPREFIX]:-}}"
        expanded="''${expanded//\$HOME/$HOME}"
        base=$(basename "$expanded")
        parent=$(dirname "$expanded")
        if [[ ! -d "$parent" ]]; then
          echo "[mirror] skip (parent missing): $expanded" >> "$run_dir/system/mirrors.log"
          continue
        fi
        tail -F -n +0 -q --silent "$expanded" > "$run_dir/internal/$base" 2>/dev/null &
        mirror_pids+=($!)
      done

      scope_unit="game-$game-$runid.scope"
      launch_exit=0

      # shellcheck disable=SC2329  # invoked via trap
      finalize() {
        local end_iso end_epoch duration crash_kind signal_name
        end_iso=$(date --iso-8601=seconds)
        end_epoch=$(date +%s)
        duration=$(( end_epoch - start_epoch ))

        # Stop tail-based mirrors. We track tail PIDs directly so direct kill
        # suffices — no orphan watchers possible.
        if (( ''${#mirror_pids[@]} > 0 )); then
          for pid in "''${mirror_pids[@]}"; do
            kill -TERM "$pid" 2>/dev/null || true
          done
          sleep 1
          for pid in "''${mirror_pids[@]}"; do
            kill -KILL "$pid" 2>/dev/null || true
          done
        fi

        # Final mirror pass — catch anything between the last inotify event and shutdown.
        for raw in "''${internal_paths[@]}"; do
          expanded="''${raw//\$WINEPREFIX/''${env_map[WINEPREFIX]:-}}"
          expanded="''${expanded//\$HOME/$HOME}"
          if [[ -f "$expanded" ]]; then
            base=$(basename "$expanded")
            cp -a "$expanded" "$run_dir/internal/$base" 2>/dev/null || true
          fi
        done

        # Post-run system snapshots.
        if command -v nvidia-smi >/dev/null 2>&1; then
          nvidia-smi -q > "$run_dir/system/nvidia-smi-end.txt" 2>&1 || true
        fi

        # Journal slice (user scope + kernel). Use unix epoch for --since:
        # journalctl is fussy about ISO 8601 with timezone offsets and
        # silently returns one stale line for some inputs. @<epoch> always
        # works. The slice is dumped to files at capture time so it survives
        # reboots regardless of journald storage policy.
        journalctl --user --user-unit="$scope_unit" --since="@$start_epoch" -o short-iso \
          > "$run_dir/system/journal.txt" 2>&1 || true
        journalctl -k --since="@$start_epoch" -o short-iso \
          > "$run_dir/system/dmesg.log" 2>&1 || true

        # Coredumps within the run window.
        coredumpctl list --since="@$start_epoch" --no-pager \
          > "$run_dir/system/coredumps.txt" 2>&1 || true
        # Best-effort: dump cores listed since start. coredumpctl matches by
        # PID/COMM/etc.; we capture all in-window dumps and let triage filter.
        if coredumpctl list --since="@$start_epoch" --no-legend >/dev/null 2>&1; then
          while IFS= read -r line; do
            pid=$(awk '{print $5}' <<< "$line")
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            coredumpctl dump --output="$run_dir/system/coredumps/core.$pid" "$pid" \
              >/dev/null 2>&1 || true
          done < <(coredumpctl list --since="@$start_epoch" --no-legend 2>/dev/null)
        fi

        # Crash classification. Order matters — later checks win when more
        # specific. Notable: engines like UE5 catch GPU device-removed and
        # exit cleanly (exit_code=0), so we MUST scan logs even on exit 0.
        crash_kind="null"
        signal_name=""
        case "$launch_exit" in
          0)   ;;
          124) crash_kind="timeout" ;;
          134) crash_kind="signal"; signal_name="SIGABRT" ;;
          136) crash_kind="signal"; signal_name="SIGFPE"  ;;
          137) crash_kind="signal"; signal_name="SIGKILL" ;;
          139) crash_kind="signal"; signal_name="SIGSEGV" ;;
          159) crash_kind="signal"; signal_name="SIGSYS"  ;;
          *)   crash_kind="unknown" ;;
        esac
        # vkd3d-proton device-lost (Vulkan VK_ERROR_DEVICE_LOST). This is
        # what fires for UE5 + Blackwell GPU hangs; UE5 then exits 0.
        if grep -qE 'VK_ERROR_DEVICE_LOST|d3d12_device_mark_as_removed' \
             "$run_dir/vkd3d.log" 2>/dev/null; then
          crash_kind="gpu_crash"
        fi
        # Engine-side GPU crash markers (UE5 phrasing).
        if grep -qE 'GPU crash detected|DXGI_ERROR_DEVICE_REMOVED|Device .* Removed' \
             "$run_dir"/internal/*.log 2>/dev/null; then
          crash_kind="gpu_crash"
        fi
        # Engine-side fatal (non-GPU) — UE5 "Fatal error!" dialog.
        if grep -q 'LogWindows.*Fatal error\|Engine has crashed' \
             "$run_dir"/internal/*.log 2>/dev/null && [[ "$crash_kind" == "null" ]]; then
          crash_kind="engine_fatal"
        fi
        # Kernel-side NVRM Xid (real GPU fault as seen by the driver).
        if grep -q 'NVRM:.*Xid' "$run_dir/system/dmesg.log" 2>/dev/null; then
          crash_kind="gpu_fault"
        fi
        if grep -qE 'oom-kill|Out of memory.*Killed' "$run_dir/system/journal.txt" 2>/dev/null; then
          crash_kind="oom"
        fi

        # Update metadata.json.
        local crash_arg signal_arg
        if [[ "$crash_kind" == "null" ]]; then crash_arg="null"; else crash_arg="\"$crash_kind\""; fi
        if [[ -z "$signal_name" ]]; then signal_arg="null"; else signal_arg="\"$signal_name\""; fi
        jq \
          --arg ended "$end_iso" \
          --argjson duration "$duration" \
          --argjson exit "$launch_exit" \
          --argjson crash "$crash_arg" \
          --argjson signal "$signal_arg" \
          '. + { ended: $ended, duration_seconds: $duration, exit_code: $exit, crash_kind: $crash, signal: $signal }' \
          < "$run_dir/metadata.json" > "$run_dir/metadata.json.tmp" \
          && mv "$run_dir/metadata.json.tmp" "$run_dir/metadata.json"

        if [[ "$crash_kind" != "null" ]]; then
          ln -sfn "$runid" "$state_dir/$game/runs/last-crash"
        fi

        [[ -n "$gcroot_link" ]] && rm -f "$gcroot_link"

        # Retention GC: keep last $retain_runs normal + last $retain_crashes crashes.
        gc_runs "$state_dir/$game/runs"

        echo
        echo "[gamerun] $game/$runid finished: exit=$launch_exit crash_kind=$crash_kind duration=''${duration}s"
        echo "[gamerun] logs: $run_dir"
      }

      # shellcheck disable=SC2329  # invoked from finalize (trap)
      gc_runs() {
        local runs_dir="$1"
        local -a all crashed=() normal=()
        mapfile -t all < <(find "$runs_dir" -maxdepth 1 -mindepth 1 -type d ! -lname '*' -printf '%f\n' | sort)
        for r in "''${all[@]}"; do
          if [[ -f "$runs_dir/$r/metadata.json" ]] \
             && jq -e '.crash_kind != null' < "$runs_dir/$r/metadata.json" >/dev/null 2>&1; then
            crashed+=("$r")
          else
            normal+=("$r")
          fi
        done

        # Mark the most-recent N of each class to keep. Explicit indexing
        # avoids the bash gotcha where ''${arr[@]: -N} returns empty when
        # N exceeds array length.
        local -A keep=()
        local total_c=''${#crashed[@]} total_n=''${#normal[@]}
        local first_c=$(( total_c > retain_crashes ? total_c - retain_crashes : 0 ))
        local first_n=$(( total_n > retain_runs    ? total_n - retain_runs    : 0 ))
        local i
        for (( i = first_c; i < total_c; i++ )); do keep["''${crashed[$i]}"]=1; done
        for (( i = first_n; i < total_n; i++ )); do keep["''${normal[$i]}"]=1;  done

        for r in "''${all[@]}"; do
          [[ -n "''${keep[$r]:-}" ]] && continue
          # :? guards against `rm -rf /` if either var is empty.
          rm -rf "''${runs_dir:?}/''${r:?}"
        done
      }

      # shellcheck disable=SC2329  # invoked via trap
      forward_signal() {
        # Forward into the scope so the game gets a chance to clean up.
        systemctl --user kill --signal="$1" "$scope_unit" 2>/dev/null || true
      }

      trap finalize EXIT
      trap 'forward_signal TERM' TERM
      trap 'forward_signal INT'  INT

      # Build --setenv args for systemd-run.
      setenv_args=()
      for k in "''${!env_map[@]}"; do
        setenv_args+=("--setenv=$k=''${env_map[$k]}")
      done

      # Launch the scope. stdout/stderr go to files via shell redirection
      # inherited by the inner process, so they survive wrapper death.
      # `set +e` is needed because we want to capture the exit code rather
      # than die on it; trap-EXIT runs finalize() with launch_exit set.
      set +e
      systemd-run --user --scope --collect --quiet \
        --unit="$scope_unit" \
        --setenv=GAME_RUN_ID="$runid" \
        --setenv=GAMELOGS_RUN_DIR="$run_dir" \
        "''${setenv_args[@]}" \
        -- "''${cmd[@]}" \
        > "$run_dir/stdout.log" \
        2> "$run_dir/stderr.log"
      launch_exit=$?
      set -e

      exit "$launch_exit"
    '';
  };

  gamelogsCli = pkgs.writeShellApplication {
    name = "gamelogs";
    runtimeInputs = with pkgs; [
      jq
      ripgrep
      zstd
      gnutar
      coreutils
      findutils
      gnugrep
      systemd
    ];
    text = ''
      # gamelogs <subcommand> [args...]
      #
      # Subcommands:
      #   list [--game=NAME] [--json]
      #   show GAME [RUNID] [--json]
      #   cat GAME [RUNID] STREAM   # stdout|stderr|wine|vkd3d|journal|dmesg|engine
      #   tail GAME                 # alias for `gamewatch GAME`
      #   grep GAME [RUNID] PATTERN
      #   dump GAME [RUNID] [--out=PATH]
      #   sessions                  # list running game scopes

      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/games"

      resolve_runid() {
        local game="$1" runid="''${2:-latest}"
        if [[ "$runid" == "latest" || "$runid" == "last-crash" ]]; then
          if [[ -L "$state_dir/$game/runs/$runid" ]]; then
            runid=$(readlink "$state_dir/$game/runs/$runid")
          else
            echo "No '$runid' run for $game" >&2
            return 1
          fi
        fi
        if [[ ! -d "$state_dir/$game/runs/$runid" ]]; then
          echo "Run not found: $state_dir/$game/runs/$runid" >&2
          return 1
        fi
        printf '%s' "$runid"
      }

      cmd_list() {
        local filter_game="" json=0
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --game=*) filter_game="''${1#--game=}"; shift ;;
            --json)   json=1; shift ;;
            *) echo "unknown flag: $1" >&2; return 1 ;;
          esac
        done
        if [[ ! -t 1 ]]; then json=1; fi

        if [[ ! -d "$state_dir" ]]; then
          if (( json )); then echo "[]"; else echo "(no runs)"; fi
          return 0
        fi

        if (( json )); then
          local first=1
          printf '['
          for game_dir in "$state_dir"/*/; do
            [[ -d "''${game_dir}runs" ]] || continue
            local game; game=$(basename "$game_dir")
            [[ -n "$filter_game" && "$game" != "$filter_game" ]] && continue
            while IFS= read -r run_dir; do
              [[ -f "$run_dir/metadata.json" ]] || continue
              (( first )) || printf ','
              first=0
              jq -c --arg dir "$run_dir" '. + {dir: $dir}' < "$run_dir/metadata.json"
            done < <(find "''${game_dir}runs" -maxdepth 1 -mindepth 1 -type d ! -lname '*' | sort -r)
          done
          printf ']\n'
        else
          printf '%-12s %-25s %-9s %-6s %-10s %s\n' GAME RUNID DURATION EXIT CRASH STARTED
          for game_dir in "$state_dir"/*/; do
            [[ -d "''${game_dir}runs" ]] || continue
            local game; game=$(basename "$game_dir")
            [[ -n "$filter_game" && "$game" != "$filter_game" ]] && continue
            while IFS= read -r run_dir; do
              [[ -f "$run_dir/metadata.json" ]] || continue
              local data
              data=$(jq -r '[.runid, (.duration_seconds // 0), (.exit_code // "?"), (.crash_kind // "-"), .started] | @tsv' \
                < "$run_dir/metadata.json")
              IFS=$'\t' read -r runid duration exit_code crash started <<< "$data"
              printf '%-12s %-25s %-9s %-6s %-10s %s\n' \
                "$game" "$runid" "''${duration}s" "$exit_code" "$crash" "$started"
            done < <(find "''${game_dir}runs" -maxdepth 1 -mindepth 1 -type d ! -lname '*' | sort -r)
          done
        fi
      }

      cmd_show() {
        local game="''${1:-}" runid="''${2:-latest}" json=0
        [[ -z "$game" ]] && { echo "Usage: gamelogs show GAME [RUNID] [--json]" >&2; return 1; }
        shift || true
        # If the second arg starts with a digit (looks like a runid), use it as runid;
        # otherwise treat it as a flag.
        if [[ "''${1:-}" =~ ^[0-9]{8}- ]]; then
          runid="$1"; shift
        fi
        [[ "''${1:-}" == "--json" ]] && json=1

        runid=$(resolve_runid "$game" "$runid") || return 1
        local rd="$state_dir/$game/runs/$runid"

        if (( json )) || [[ ! -t 1 ]]; then
          local files_json
          files_json=$(find "$rd" -type f -printf '%P\n' | jq -Rsc 'split("\n") | map(select(. != ""))')
          jq --arg dir "$rd" --argjson files "$files_json" \
            '. + {dir: $dir, files: $files}' < "$rd/metadata.json"
        else
          jq -C '.' < "$rd/metadata.json"
          echo
          echo "Files (under $rd):"
          find "$rd" -type f -printf '%s\t%P\n' \
            | sort -k2 \
            | awk -F'\t' 'BEGIN{OFS="\t"}{
                s=$1; u="B";
                if(s>1024){s=s/1024; u="K"}
                if(s>1024){s=s/1024; u="M"}
                printf "  %7.1f%s  %s\n", s, u, $2
              }'
        fi
      }

      cmd_cat() {
        local game="''${1:-}"
        [[ -z "$game" ]] && { echo "Usage: gamelogs cat GAME [RUNID] STREAM" >&2; return 1; }
        shift
        local runid stream
        if [[ "''${1:-}" =~ ^[0-9]{8}- ]]; then
          runid="$1"; stream="''${2:-}"
        else
          runid="latest"; stream="''${1:-}"
        fi
        [[ -z "$stream" ]] && { echo "Missing STREAM" >&2; return 1; }
        runid=$(resolve_runid "$game" "$runid") || return 1
        local rd="$state_dir/$game/runs/$runid"

        case "$stream" in
          stdout)  cat "$rd/stdout.log" ;;
          stderr)  cat "$rd/stderr.log" ;;
          wine)    cat "$rd/wine.log" 2>/dev/null || echo "(no wine.log)" ;;
          vkd3d)   cat "$rd/vkd3d.log" 2>/dev/null || echo "(no vkd3d.log)" ;;
          journal) cat "$rd/system/journal.txt" ;;
          dmesg)   cat "$rd/system/dmesg.log" ;;
          engine)
            if compgen -G "$rd/internal/*" > /dev/null; then
              for f in "$rd"/internal/*; do
                echo "==> $f <=="
                cat "$f"
              done
            else
              echo "(no engine logs)"
            fi
            ;;
          metadata) cat "$rd/metadata.json" ;;
          *) echo "Unknown stream '$stream' (stdout|stderr|wine|vkd3d|journal|dmesg|engine|metadata)" >&2; return 1 ;;
        esac
      }

      cmd_grep() {
        local game="''${1:-}"
        [[ -z "$game" ]] && { echo "Usage: gamelogs grep GAME [RUNID] PATTERN" >&2; return 1; }
        shift
        local runid pattern
        if [[ "''${1:-}" =~ ^[0-9]{8}- ]]; then
          runid="$1"; pattern="''${2:-}"
        else
          runid="latest"; pattern="''${1:-}"
        fi
        [[ -z "$pattern" ]] && { echo "Missing PATTERN" >&2; return 1; }
        runid=$(resolve_runid "$game" "$runid") || return 1
        rg --no-ignore --color=auto "$pattern" "$state_dir/$game/runs/$runid"
      }

      cmd_dump() {
        local game="''${1:-}"
        [[ -z "$game" ]] && { echo "Usage: gamelogs dump GAME [RUNID] [--out=PATH]" >&2; return 1; }
        shift
        local runid="latest" out=""
        if [[ "''${1:-}" =~ ^[0-9]{8}- ]]; then
          runid="$1"; shift
        fi
        while [[ $# -gt 0 ]]; do
          case "$1" in --out=*) out="''${1#--out=}"; shift ;; *) shift ;; esac
        done
        runid=$(resolve_runid "$game" "$runid") || return 1
        [[ -z "$out" ]] && out="./gamelogs-$game-$runid.tar.zst"
        tar -C "$state_dir/$game/runs" --zstd -cf "$out" "$runid"
        echo "Dumped $state_dir/$game/runs/$runid -> $out"
      }

      cmd_sessions() {
        systemctl --user list-units 'game-*.scope' --no-pager 2>/dev/null \
          || echo "(no active game scopes)"
      }

      case "''${1:-}" in
        list)     shift; cmd_list "$@" ;;
        show)     shift; cmd_show "$@" ;;
        cat)      shift; cmd_cat "$@" ;;
        grep)     shift; cmd_grep "$@" ;;
        dump)     shift; cmd_dump "$@" ;;
        tail)     shift; exec gamewatch "$@" ;;
        sessions) shift; cmd_sessions "$@" ;;
        ""|-h|--help)
          cat <<'EOF'
      Usage: gamelogs <subcommand> [args...]

      Subcommands:
        list [--game=NAME] [--json]   table of all runs (JSON when piped)
        show GAME [RUNID] [--json]    metadata + file manifest for one run
        cat  GAME [RUNID] STREAM      print one stream (see below)
        grep GAME [RUNID] PATTERN     ripgrep across the run dir
        dump GAME [RUNID] [--out=…]   tar.zst archive of the run dir
        tail GAME                     live multi-file tail (lnav)
        sessions                      list active game scopes

      Streams: stdout | stderr | wine | vkd3d | journal | dmesg | engine | metadata
      EOF
          ;;
        *) echo "Unknown subcommand: $1" >&2; exit 1 ;;
      esac
    '';
  };

  gamewatch = pkgs.writeShellApplication {
    name = "gamewatch";
    runtimeInputs = with pkgs; [
      jq
      lnav
      coreutils
      findutils
    ];
    text = ''
      # gamewatch <game> [RUNID]
      # Live-tail every log file in the run dir using lnav (timestamp-merged
      # multi-file view). Falls back to `tail -F` if lnav can't run.

      game="''${1:-}"
      runid="''${2:-latest}"

      if [[ -z "$game" ]]; then
        echo "Usage: gamewatch <game> [RUNID]" >&2
        exit 1
      fi

      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/games"

      if [[ "$runid" == "latest" || "$runid" == "last-crash" ]]; then
        if [[ ! -L "$state_dir/$game/runs/$runid" ]]; then
          echo "No '$runid' run for $game" >&2; exit 1
        fi
        runid=$(readlink "$state_dir/$game/runs/$runid")
      fi
      rd="$state_dir/$game/runs/$runid"
      [[ -d "$rd" ]] || { echo "Run not found: $rd" >&2; exit 1; }

      mapfile -t files < <(find "$rd" -type f \
        \( -name '*.log' -o -name '*.txt' -o -name 'stdout.log' -o -name 'stderr.log' \) \
        ! -path '*/coredumps/*' \
        | sort)
      if (( ''${#files[@]} == 0 )); then
        echo "No log files yet in $rd" >&2; exit 1
      fi

      if [[ -t 1 ]] && command -v lnav >/dev/null 2>&1; then
        exec lnav -t "''${files[@]}"
      else
        exec tail -F "''${files[@]}"
      fi
    '';
  };

in
{
  options.gamelogs = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the game log capture harness (gamerun/gamelogs/gamewatch).";
    };

    retainRuns = mkOption {
      type = types.int;
      default = 20;
      description = "Number of normal (non-crash) runs to retain per game.";
    };

    retainCrashes = mkOption {
      type = types.int;
      default = 5;
      description = "Number of crashed runs to retain per game (sticky beyond retainRuns).";
    };

    minFreeMb = mkOption {
      type = types.int;
      default = 2048;
      description = "Pre-launch disk-space floor (MB) on the state-dir partition.";
    };

    defaultEnv = mkOption {
      type = types.attrsOf types.str;
      default = {
        # Targeted Wine channels — quiet during gameplay, fire only on
        # interesting events (exception unwind, DLL load).
        WINEDEBUG = "+seh,+unwind,+module,+pid,+tid,+timestamp";
        # DXVK at warn — info dumps swapchain init + every frame's adapter
        # state changes, way too noisy for normal runs.
        DXVK_LOG_LEVEL = "warn";
        # VKD3D warn-only; bump via --debug for triage.
        VKD3D_DEBUG = "warn";
        # Breadcrumbs add per-command-list markers that survive a hang —
        # cheap and high-signal for GPU crash triage.
        VKD3D_CONFIG = "breadcrumbs";
        DXVK_NVAPI_LOG_LEVEL = "warn";
        # NB: PROTON_LOG=1 is intentionally NOT a default. It generates
        # 1+ GB/hour of synchronous Wine trace output during gameplay,
        # itself causing stutters. Use `gamerun --debug` to enable.
      };
      description = ''
        Env vars set by gamerun for every game. Per-game `extraEnv` wins on conflicts.
        Log-output paths (DXVK_LOG_PATH, VKD3D_LOG_FILE, etc.) are always overridden
        by gamerun to point inside the run dir, regardless of what's set here.
      '';
    };

    games = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          wrapperOf = mkOption {
            type = types.str;
            description = "Underlying launcher binary (informational; e.g. \"umu-run\").";
          };
          engine = mkOption {
            type = types.enum [ "ue5" "unity" "source" "native" "unknown" ];
            default = "unknown";
          };
          internalPaths = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              Paths to log files written by the game/launcher inside the prefix.
              gamerun watches each via inotify and mirrors copies into the run dir.
              Supports `$WINEPREFIX` and `$HOME` expansion.
            '';
          };
          extraEnv = mkOption {
            type = types.attrsOf types.str;
            default = { };
            description = "Env vars merged over `defaultEnv` for this game.";
          };
          crashHooks = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Reserved; commands to run on non-zero exit (not implemented yet).";
          };
        };
      });
      default = { };
    };
  };

  config = mkIf cfg.enable {
    environment.etc."gamelogs/registry.json".source = registryJson;

    environment.systemPackages = [
      gamerun
      gamelogsCli
      gamewatch
    ] ++ (with pkgs; [
      lnav
      jq
      ripgrep
      inotify-tools
    ]);
  };
}
