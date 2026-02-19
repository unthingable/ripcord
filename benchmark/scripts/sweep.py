#!/usr/bin/env python3
"""
Parameter sweep for diarization tuning.

Two-stage weighted sweep against benchmark datasets:
  Stage 1: Coarse one-at-a-time + focused grid on VoxConverse only
  Stage 2: Validate top combos on both VoxConverse and AMI

Usage (via benchmark.sh):
    ./benchmark.sh sweep [options]

Direct usage:
    python sweep.py --transcribe PATH --data-dir DIR --results-dir DIR --lists-dir DIR [options]
"""

import argparse
import concurrent.futures
import itertools
import json
import os
import subprocess
import sys
import time

# Import scoring functions from score.py in the same directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from json_to_rttm import json_to_rttm
from score import compute_der_with_mapping, parse_rttm

# Parameter ranges for coarse sweep
PARAM_RANGES = {
    "sensitivity": [0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85],
    "speech_threshold": [0.3, 0.4, 0.5, 0.6, 0.7],
    "min_segment": [0.05, 0.1, 0.2, 0.5, 1.0],
    "min_gap": [0.0, 0.1, 0.3, 0.5],
}

# Defaults (what Transcriber uses when CLI passes nil)
DEFAULTS = {
    "sensitivity": None,
    "speech_threshold": None,
    "min_segment": None,
    "min_gap": None,
}


def combo_id(params):
    """Generate a short directory-safe identifier for a parameter combo."""
    parts = []
    for key in sorted(params.keys()):
        val = params[key]
        if key == "sensitivity":
            parts.append(f"t{val}" if val is not None else "tD")
        elif key == "speech_threshold":
            parts.append(f"s{val}" if val is not None else "sD")
        elif key == "min_segment":
            parts.append(f"ms{val}" if val is not None else "msD")
        elif key == "min_gap":
            parts.append(f"mg{val}" if val is not None else "mgD")
    return "_".join(parts)


def params_to_cli_flags(params):
    """Convert parameter dict to CLI flags for the transcribe binary."""
    flags = []
    if params.get("sensitivity") is not None:
        flags += ["--sensitivity", str(params["sensitivity"])]
    if params.get("speech_threshold") is not None:
        flags += ["--speech-threshold", str(params["speech_threshold"])]
    if params.get("min_segment") is not None:
        flags += ["--min-segment", str(params["min_segment"])]
    if params.get("min_gap") is not None:
        flags += ["--min-gap", str(params["min_gap"])]
    return flags


def find_audio_file(audio_dir, base_name, suffixes=None):
    """Find audio file with m4a or wav extension, optionally with suffixes to try."""
    if suffixes is None:
        suffixes = [""]
    for suffix in suffixes:
        for ext in ("m4a", "wav"):
            path = os.path.join(audio_dir, f"{base_name}{suffix}.{ext}")
            if os.path.isfile(path):
                return path
    return None


def load_file_list(list_path):
    """Load a list file, skipping comments and blank lines."""
    names = []
    with open(list_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            names.append(line)
    return names


def run_transcription(transcribe_bin, audio_path, output_json, cli_flags):
    """Run the transcribe binary on a single audio file."""
    cmd = [transcribe_bin, audio_path, "--format", "json", "-o", output_json, "--force"]
    cmd += cli_flags
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return False, result.stderr
    return True, ""


def log_msg(msg):
    """Print a message and flush immediately (needed for parallel workers)."""
    print(msg, flush=True)


def run_combo_on_dataset(
    transcribe_bin, params, dataset_name, audio_dir, ref_dir,
    results_base, file_list, audio_suffix="",
):
    """Run a parameter combo on a dataset.

    Returns (combo_id, result_tuple) where result_tuple is
    (der, missed, fa, conf, ref_total) or None.
    """
    cid = combo_id(params)
    combo_dir = os.path.join(results_base, cid, dataset_name)
    os.makedirs(combo_dir, exist_ok=True)

    cli_flags = params_to_cli_flags(params)
    audio_suffixes = [audio_suffix] if audio_suffix else [""]

    total_missed = 0.0
    total_fa = 0.0
    total_conf = 0.0
    total_ref = 0.0
    scored_files = 0

    for name in file_list:
        out_json = os.path.join(combo_dir, f"{name}.json")
        out_rttm = os.path.join(combo_dir, f"{name}.rttm")
        ref_rttm = os.path.join(ref_dir, f"{name}.rttm")

        if not os.path.isfile(ref_rttm):
            continue

        # Skip if RTTM already exists (resume-friendly)
        if not os.path.isfile(out_rttm):
            audio_path = find_audio_file(audio_dir, name, audio_suffixes)
            if audio_path is None:
                log_msg(f"  [{cid}] {name}: audio not found, skipping")
                continue

            log_msg(f"  [{cid}] {name}: transcribing...")
            ok, stderr = run_transcription(transcribe_bin, audio_path, out_json, cli_flags)
            if not ok:
                log_msg(f"  [{cid}] ERROR: transcribe failed for {audio_path}")
                if stderr:
                    for line in stderr.strip().split("\n")[:5]:
                        log_msg(f"    {line}")
                continue

            # Convert JSON to RTTM
            lines = json_to_rttm(out_json)
            with open(out_rttm, "w") as f:
                f.write("\n".join(lines) + "\n" if lines else "")

        # Score
        ref_segs = parse_rttm(ref_rttm)
        sys_segs = parse_rttm(out_rttm)
        if not ref_segs:
            continue

        der, miss, fa, conf, ref_s = compute_der_with_mapping(ref_segs, sys_segs)
        total_missed += miss
        total_fa += fa
        total_conf += conf
        total_ref += ref_s
        scored_files += 1

    if total_ref == 0:
        return cid, None

    overall_der = (total_missed + total_fa + total_conf) / total_ref
    return cid, (overall_der, total_missed, total_fa, total_conf, total_ref)


def _run_combo_worker(args_tuple):
    """Worker function for parallel execution. Unpacks args and calls run_combo_on_dataset."""
    transcribe_bin, params, dataset_name, audio_dir, ref_dir, results_base, file_list, audio_suffix = args_tuple
    cid, result = run_combo_on_dataset(
        transcribe_bin, params, dataset_name, audio_dir, ref_dir,
        results_base, file_list, audio_suffix,
    )
    return params, cid, result


def run_combos_parallel(transcribe_bin, combos, dataset_name, audio_dir, ref_dir,
                        sweep_dir, file_list, workers, audio_suffix=""):
    """Run a list of combos, parallelizing across workers. Returns list of (params, result)."""
    results = []

    if workers <= 1:
        # Sequential
        for i, params in enumerate(combos, 1):
            cid = combo_id(params)
            print(f"[{i}/{len(combos)}] {cid}", flush=True)
            print(f"  Params: {format_params(params)}", flush=True)

            t0 = time.time()
            _, result = run_combo_on_dataset(
                transcribe_bin, params, dataset_name,
                audio_dir, ref_dir, sweep_dir, file_list, audio_suffix,
            )
            elapsed = time.time() - t0

            if result is not None:
                der, miss, fa, conf, ref_s = result
                results.append((params, result))
                print(f"  DER={der:.1%} (miss={miss:.1f}s fa={fa:.1f}s conf={conf:.1f}s) [{elapsed:.0f}s]")
            else:
                print(f"  No results (scoring failed) [{elapsed:.0f}s]")
            print()
    else:
        # Parallel: submit all combos, per-file progress prints from workers
        print(f"  Running {len(combos)} combos with {workers} workers...", flush=True)
        print(flush=True)
        work_items = [
            (transcribe_bin, params, dataset_name, audio_dir, ref_dir, sweep_dir, file_list, audio_suffix)
            for params in combos
        ]
        completed = 0
        with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as executor:
            futures = {
                executor.submit(_run_combo_worker, item): item[1]  # item[1] = params
                for item in work_items
            }
            for future in concurrent.futures.as_completed(futures):
                completed += 1
                params, cid, result = future.result()
                if result is not None:
                    der, miss, fa, conf, ref_s = result
                    results.append((params, result))
                    print(f"[{completed}/{len(combos)}] {cid}: DER={der:.1%} (miss={miss:.1f}s fa={fa:.1f}s conf={conf:.1f}s)", flush=True)
                else:
                    print(f"[{completed}/{len(combos)}] {cid}: no results", flush=True)
        print()

    return results


def generate_coarse_combos():
    """Generate one-at-a-time sweep combos (vary each param independently)."""
    combos = []
    for param_name, values in PARAM_RANGES.items():
        for val in values:
            params = dict(DEFAULTS)
            params[param_name] = val
            combos.append(params)
    # Deduplicate (the all-defaults combo shouldn't appear multiple times)
    seen = set()
    unique = []
    for p in combos:
        cid = combo_id(p)
        if cid not in seen:
            seen.add(cid)
            unique.append(p)
    return unique


def generate_grid_combos(best_per_param, top_n=2):
    """Generate focused grid from top-N values per parameter."""
    param_values = {}
    for param_name, ranked_values in best_per_param.items():
        param_values[param_name] = ranked_values[:top_n]

    combos = []
    keys = sorted(param_values.keys())
    for vals in itertools.product(*(param_values[k] for k in keys)):
        params = dict(zip(keys, vals))
        combos.append(params)
    return combos


def find_best_per_param(results):
    """From coarse sweep results, find best values for each parameter.

    Returns dict: param_name -> list of values sorted by DER (best first).
    """
    best = {}
    for param_name in PARAM_RANGES:
        # Filter results where only this param was varied
        param_results = []
        for params, der_info in results:
            # Check that all other params are at defaults
            other_at_default = all(
                params[k] == DEFAULTS[k]
                for k in DEFAULTS
                if k != param_name
            )
            if other_at_default and params[param_name] is not None:
                param_results.append((params[param_name], der_info[0]))

        # Sort by DER ascending
        param_results.sort(key=lambda x: x[1])
        best[param_name] = [val for val, _ in param_results]
    return best


def print_leaderboard(ranked_results, datasets_shown):
    """Print a formatted leaderboard table."""
    header_parts = [f"{'Rank':<5}", f"{'Combo':<30}"]
    for ds in datasets_shown:
        header_parts.append(f"{ds:>12}")
    if len(datasets_shown) > 1:
        header_parts.append(f"{'Weighted':>12}")
    header = " ".join(header_parts)
    print(header)
    print("-" * len(header))

    for i, entry in enumerate(ranked_results, 1):
        parts = [f"{i:<5}", f"{entry['combo_id']:<30}"]
        for ds in datasets_shown:
            if ds in entry["scores"]:
                parts.append(f"{entry['scores'][ds]['der']:>11.1%}")
            else:
                parts.append(f"{'—':>12}")
        if len(datasets_shown) > 1 and "weighted_der" in entry:
            parts.append(f"{entry['weighted_der']:>11.1%}")
        print(" ".join(parts))


def save_results(results_dir, all_results):
    """Save machine-readable results to JSON."""
    out_path = os.path.join(results_dir, "results.json")
    with open(out_path, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"\nResults saved to {out_path}")


def format_params(params):
    """Format params for display."""
    parts = []
    for k in ("sensitivity", "speech_threshold", "min_segment", "min_gap"):
        v = params.get(k)
        if v is not None:
            parts.append(f"{k}={v}")
    return ", ".join(parts) if parts else "(all defaults)"


def run_stage1(args, vc_file_list, vc_audio_dir, vc_ref_dir, sweep_dir):
    """Stage 1: Coarse sweep + focused grid on VoxConverse."""
    workers = getattr(args, "workers", 1)

    print("=" * 70)
    print("STAGE 1: Coarse parameter sweep on VoxConverse")
    if workers > 1:
        print(f"  ({workers} parallel workers)")
    print("=" * 70)
    print()

    # Phase 1a: One-at-a-time sweep
    coarse_combos = generate_coarse_combos()
    print(f"Phase 1a: {len(coarse_combos)} one-at-a-time combos")
    if args.max_combos:
        coarse_combos = coarse_combos[: args.max_combos]
        print(f"  (limited to {args.max_combos} combos by --max-combos)")
    print()

    if args.dry_run:
        for p in coarse_combos:
            print(f"  {combo_id(p):30s}  {format_params(p)}")
        est_minutes = len(coarse_combos) * 16 // max(workers, 1)
        print(f"\nEstimated runtime: ~{est_minutes // 60}h {est_minutes % 60}m")
        print(f"  ({len(coarse_combos)} combos × ~16 min/combo, {workers} worker(s))")
        return []

    coarse_results = run_combos_parallel(
        args.transcribe, coarse_combos, "voxconverse",
        vc_audio_dir, vc_ref_dir, sweep_dir, vc_file_list, workers,
    )

    if not coarse_results:
        print("No coarse results. Stopping.")
        return []

    # Sort by DER
    coarse_results.sort(key=lambda x: x[1][0])
    print("--- Coarse sweep results (sorted by VoxConverse DER) ---")
    for i, (params, (der, miss, fa, conf, ref_s)) in enumerate(coarse_results, 1):
        print(f"  {i:2d}. {combo_id(params):30s}  DER={der:.1%}")
    print()

    # Phase 1b: Focused grid from top-2 per parameter
    best_per_param = find_best_per_param(coarse_results)
    print("Best values per parameter:")
    for param_name, values in sorted(best_per_param.items()):
        print(f"  {param_name}: {values[:3]}")
    print()

    grid_combos = generate_grid_combos(best_per_param, top_n=2)
    # Remove combos already run in coarse phase
    coarse_ids = {combo_id(p) for p, _ in coarse_results}
    grid_combos = [p for p in grid_combos if combo_id(p) not in coarse_ids]

    if args.max_combos:
        grid_combos = grid_combos[: args.max_combos]

    print(f"Phase 1b: {len(grid_combos)} grid combos (after dedup)")
    print()

    grid_results = run_combos_parallel(
        args.transcribe, grid_combos, "voxconverse",
        vc_audio_dir, vc_ref_dir, sweep_dir, vc_file_list, workers,
    )

    # Merge and rank all Stage 1 results
    all_results = coarse_results + grid_results
    all_results.sort(key=lambda x: x[1][0])

    print("=" * 70)
    print("STAGE 1 LEADERBOARD (VoxConverse DER)")
    print("=" * 70)
    for i, (params, (der, miss, fa, conf, ref_s)) in enumerate(all_results[:20], 1):
        print(f"  {i:2d}. {combo_id(params):30s}  DER={der:.1%}  miss={miss/ref_s:.1%} fa={fa/ref_s:.1%} conf={conf/ref_s:.1%}")
    print()

    return all_results


def run_stage2(args, all_stage1, vc_file_list, ami_file_list,
               vc_audio_dir, vc_ref_dir, ami_audio_dir, ami_ref_dir, sweep_dir):
    """Stage 2: Validate top combos on both datasets."""
    workers = getattr(args, "workers", 1)
    top_n = min(args.top_n, len(all_stage1))
    top_combos = all_stage1[:top_n]

    print("=" * 70)
    print(f"STAGE 2: Validate top {top_n} combos on VoxConverse + AMI")
    if workers > 1:
        print(f"  ({workers} parallel workers)")
    print("=" * 70)
    print()

    if args.dry_run:
        for params, (vc_der, *_) in top_combos:
            print(f"  {combo_id(params):30s}  VoxConverse DER={vc_der:.1%}")
        est_minutes = top_n * 100 // max(workers, 1)
        print(f"\nEstimated runtime: ~{est_minutes // 60}h {est_minutes % 60}m")
        print(f"  ({top_n} combos × ~100 min/combo on AMI, {workers} worker(s))")
        return

    # Run AMI combos (potentially in parallel)
    ami_combos = [params for params, _ in top_combos]
    ami_results_list = run_combos_parallel(
        args.transcribe, ami_combos, "ami",
        ami_audio_dir, ami_ref_dir, sweep_dir, ami_file_list, workers,
        audio_suffix=".Mix-Headset",
    )

    # Index AMI results by combo_id for lookup
    ami_by_id = {combo_id(params): result for params, result in ami_results_list}

    # Build final results combining VoxConverse (from Stage 1) and AMI
    final_results = []
    for params, vc_result in top_combos:
        cid = combo_id(params)
        vc_der = vc_result[0]
        entry = {
            "combo_id": cid,
            "params": params,
            "scores": {
                "voxconverse": {
                    "der": vc_result[0],
                    "missed": vc_result[1],
                    "false_alarm": vc_result[2],
                    "confusion": vc_result[3],
                    "ref_total": vc_result[4],
                },
            },
        }

        ami_result = ami_by_id.get(cid)
        if ami_result is not None:
            ami_der = ami_result[0]
            entry["scores"]["ami"] = {
                "der": ami_result[0],
                "missed": ami_result[1],
                "false_alarm": ami_result[2],
                "confusion": ami_result[3],
                "ref_total": ami_result[4],
            }
            entry["weighted_der"] = 0.8 * vc_der + 0.2 * ami_der
        else:
            entry["weighted_der"] = vc_der

        final_results.append(entry)

    # Sort by weighted DER
    final_results.sort(key=lambda x: x["weighted_der"])

    print("=" * 70)
    print("FINAL LEADERBOARD (0.8 × VoxConverse + 0.2 × AMI)")
    print("=" * 70)
    datasets = ["voxconverse", "ami"]
    print_leaderboard(final_results, datasets)
    print()

    # Save results
    save_results(os.path.join(sweep_dir), final_results)


def main():
    parser = argparse.ArgumentParser(
        description="Parameter sweep for diarization tuning"
    )
    parser.add_argument(
        "--transcribe", required=True,
        help="Path to the transcribe binary",
    )
    parser.add_argument(
        "--data-dir", required=True,
        help="Path to benchmark data directory",
    )
    parser.add_argument(
        "--results-dir", required=True,
        help="Path to benchmark results directory",
    )
    parser.add_argument(
        "--lists-dir", required=True,
        help="Path to benchmark list files directory",
    )
    parser.add_argument(
        "--stage", type=int, choices=[1, 2], default=None,
        help="Run only this stage (default: both)",
    )
    parser.add_argument(
        "--max-combos", type=int, default=None,
        help="Limit number of combos per phase (for testing)",
    )
    parser.add_argument(
        "--max-files", type=int, default=None,
        help="Limit number of audio files per dataset (for testing)",
    )
    parser.add_argument(
        "--top-n", type=int, default=5,
        help="Number of top combos to validate in Stage 2 (default: 5)",
    )
    parser.add_argument(
        "--workers", type=int, default=1,
        help="Number of parallel workers (each loads its own model; default: 1)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print parameter grid and estimated runtime without running",
    )
    args = parser.parse_args()

    # Resolve paths
    data_dir = args.data_dir
    results_dir = args.results_dir
    lists_dir = args.lists_dir
    sweep_dir = os.path.join(results_dir, "sweep")
    os.makedirs(sweep_dir, exist_ok=True)

    # VoxConverse paths
    vc_audio_dir = os.path.join(data_dir, "voxconverse", "audio")
    vc_ref_dir = os.path.join(data_dir, "voxconverse", "rttm")
    # Use full dev set if available, otherwise quick list
    vc_full_list = os.path.join(lists_dir, "voxconverse_quick.txt")
    # Discover all available VoxConverse audio files
    vc_file_list = []
    if os.path.isdir(vc_audio_dir):
        seen = set()
        for f in sorted(os.listdir(vc_audio_dir)):
            base, ext = os.path.splitext(f)
            if ext in (".m4a", ".wav") and base not in seen:
                # Only include if we have a reference RTTM
                if os.path.isfile(os.path.join(vc_ref_dir, f"{base}.rttm")):
                    seen.add(base)
                    vc_file_list.append(base)
    if not vc_file_list:
        # Fall back to quick list
        vc_file_list = load_file_list(vc_full_list)
    if args.max_files:
        vc_file_list = vc_file_list[: args.max_files]
    print(f"VoxConverse: {len(vc_file_list)} files")

    # AMI paths
    ami_audio_dir = os.path.join(data_dir, "ami", "audio")
    ami_ref_dir = os.path.join(data_dir, "ami", "rttm")
    ami_quick_list = os.path.join(lists_dir, "ami_quick.txt")
    ami_file_list = load_file_list(ami_quick_list)
    if args.max_files:
        ami_file_list = ami_file_list[: args.max_files]
    print(f"AMI: {len(ami_file_list)} files")
    print()

    # Verify transcribe binary
    if not os.path.isfile(args.transcribe) or not os.access(args.transcribe, os.X_OK):
        print(f"ERROR: transcribe binary not found or not executable: {args.transcribe}")
        sys.exit(1)

    # Run stages
    run_stage = args.stage
    all_stage1 = []

    if run_stage in (None, 1):
        all_stage1 = run_stage1(args, vc_file_list, vc_audio_dir, vc_ref_dir, sweep_dir)
        # Save intermediate results
        if all_stage1 and not args.dry_run:
            stage1_results = []
            for params, (der, miss, fa, conf, ref_s) in all_stage1:
                stage1_results.append({
                    "combo_id": combo_id(params),
                    "params": params,
                    "scores": {
                        "voxconverse": {
                            "der": der,
                            "missed": miss,
                            "false_alarm": fa,
                            "confusion": conf,
                            "ref_total": ref_s,
                        }
                    },
                })
            stage1_path = os.path.join(sweep_dir, "stage1_results.json")
            with open(stage1_path, "w") as f:
                json.dump(stage1_results, f, indent=2)
            print(f"Stage 1 results saved to {stage1_path}")
            print()

    if run_stage in (None, 2):
        # Load Stage 1 results if we didn't just run them
        if run_stage == 2 or not all_stage1:
            stage1_path = os.path.join(sweep_dir, "stage1_results.json")
            if not os.path.isfile(stage1_path):
                if args.dry_run:
                    print("Stage 2 dry-run: no Stage 1 results yet.")
                    print("  Run Stage 1 first, then Stage 2 will validate the top combos on AMI.")
                    print(f"  Estimated runtime: ~{args.top_n * 100 // max(args.workers, 1) // 60}h {args.top_n * 100 // max(args.workers, 1) % 60}m")
                    print(f"  ({args.top_n} combos × ~100 min/combo on AMI, {args.workers} worker(s))")
                else:
                    print("ERROR: No Stage 1 results found. Run Stage 1 first.")
                    sys.exit(1)
            else:
                with open(stage1_path) as f:
                    stage1_data = json.load(f)
                all_stage1 = []
                for entry in stage1_data:
                    params = entry["params"]
                    sc = entry["scores"]["voxconverse"]
                    result = (sc["der"], sc["missed"], sc["false_alarm"], sc["confusion"], sc["ref_total"])
                    all_stage1.append((params, result))
                all_stage1.sort(key=lambda x: x[1][0])

        if all_stage1:
            run_stage2(
                args, all_stage1, vc_file_list, ami_file_list,
                vc_audio_dir, vc_ref_dir, ami_audio_dir, ami_ref_dir, sweep_dir,
            )

    if args.dry_run:
        print("\n(Dry run — no transcriptions were executed)")


if __name__ == "__main__":
    main()
