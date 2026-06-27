#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List

COPC_URL_FIELD = "url"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build a PDAL pipeline from a local LiDAR tile footprint dataset by reading "
            "COPC URLs from the schema-defined 'url' property."
        )
    )
    parser.add_argument(
        "--tiles",
        required=True,
        help="Path to the local LiDAR tile footprint dataset, typically the generated GeoPackage.",
    )
    parser.add_argument(
        "--bbox",
        required=True,
        nargs=4,
        metavar=("XMIN", "YMIN", "XMAX", "YMAX"),
        help="Buffered extraction bounding box in EPSG:2154, forwarded to each PDAL readers.copc stage.",
    )
    parser.add_argument(
        "--output-pipeline",
        required=True,
        help="Path where the generated PDAL pipeline JSON will be written.",
    )
    parser.add_argument(
        "--laz-output",
        required=True,
        help="Path to the cropped LAZ file that the generated PDAL pipeline will write.",
    )
    return parser.parse_args()


def run_ogrinfo(dataset: str) -> dict:
    command = ["ogrinfo", "-ro", "-al", "-geom=NO", "-q", "-json", "-features", dataset]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise RuntimeError(f"failed to execute ogrinfo: {exc}") from exc

    if result.returncode != 0:
        raise RuntimeError(f"ogrinfo failed: {result.stderr.strip()}")

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"ogrinfo returned invalid JSON: {exc}") from exc


def extract_features(data: Dict[str, Any]) -> List[Dict[str, Any]]:
    root_features = data.get("features")
    if isinstance(root_features, list) and root_features:
        return root_features

    layers = data.get("layers")
    if isinstance(layers, list):
        for layer in layers:
            if not isinstance(layer, dict):
                continue

            features = layer.get("features")
            if isinstance(features, list) and features:
                return features
    return []


def ends_with_copc_laz(value: object) -> bool:
    return (
        isinstance(value, str)
        and value.lower().startswith(("http://", "https://"))
        and value.lower().endswith(".copc.laz")
    )


def format_tile_identifier(properties: Dict[str, Any]) -> str:
    tile_id = properties.get("id")
    tile_name = properties.get("name")

    if tile_id is not None and tile_name:
        return f"id={tile_id}, name={tile_name}"
    if tile_id is not None:
        return f"id={tile_id}"
    if tile_name:
        return f"name={tile_name}"
    return "<unknown tile>"


def collect_copc_urls(features: List[Dict[str, Any]]) -> List[str]:
    ordered_urls: List[str] = []
    tile_identifiers: List[str] = []
    skipped_identifiers: List[str] = []
    seen = set()

    for feature in features:
        properties = feature.get("properties") or {}
        identifier = format_tile_identifier(properties)
        tile_identifiers.append(identifier)
        value = properties.get(COPC_URL_FIELD)
        if not ends_with_copc_laz(value):
            skipped_identifiers.append(identifier)
            continue
        if value not in seen:
            seen.add(value)
            ordered_urls.append(value)

    if skipped_identifiers:
        identifiers = ", ".join(skipped_identifiers)
        print(
            f"Warning: skipped {len(skipped_identifiers)} LiDAR tile(s) without a usable "
            f"'{COPC_URL_FIELD}' COPC URL; LiDAR coverage may be incomplete. "
            f"Tiles skipped: {identifiers}",
            file=sys.stderr,
        )

    if not ordered_urls:
        identifiers = ", ".join(tile_identifiers[:10])
        raise RuntimeError(
            f"no COPC URLs collected from LiDAR tile '{COPC_URL_FIELD}' property; "
            f"tiles seen: {identifiers}"
        )

    return ordered_urls


def build_bounds_string(bbox: List[str]) -> str:
    xmin, ymin, xmax, ymax = bbox
    return f"([{xmin},{xmax}],[{ymin},{ymax}])"


def build_pipeline(urls: List[str], bounds: str, laz_output: str) -> List[Dict[str, Any]]:
    stages: List[Dict[str, Any]] = []

    for url in urls:
        stages.append(
            {
                "type": "readers.copc",
                "filename": url,
                "bounds": bounds,
            }
        )

    stages.append(
        {
            "type": "filters.assign",
            "value": ["Classification = 6 WHERE Classification == 67"],
        }
    )
    stages.append(
        {
            "type": "writers.las",
            "filename": laz_output,
            "compression": "laszip",
            "forward": "all",
        }
    )
    return stages


def main() -> int:
    args = parse_args()

    data = run_ogrinfo(args.tiles)
    features = extract_features(data)
    if not features:
        raise RuntimeError("no LiDAR tile features found in local dataset")

    urls = collect_copc_urls(features)
    bounds = build_bounds_string(args.bbox)
    pipeline = build_pipeline(urls, bounds, args.laz_output)

    try:
        Path(args.output_pipeline).write_text(json.dumps(pipeline, indent=2) + "\n", encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"failed to write pipeline file '{args.output_pipeline}': {exc}") from exc

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
