#!/usr/bin/env python3
"""Invoke the shared Swift engine; never duplicate its pricing or lifecycle logic."""
import argparse
import pathlib
import os
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('command', choices=['validate', 'review', 'csv', 'ingest', 'apply', 'air-review', 'envelope-review', 'room-review', 'change-review', 'ops-review', 'catalog-review', 'extract-text', 'extract-review', 'schedule-text', 'schedule-review', 'schedule-map-review', 'schedule-discover', 'schedule-discover-review', 'schedule-saved', 'catalog-compare', 'xlsx', 'rfi-docx', 'co-docx'])
parser.add_argument('project', type=pathlib.Path)
parser.add_argument('--request', type=pathlib.Path, help='Structured JSON edit request (apply only)')
parser.add_argument('--output', type=pathlib.Path, help='New project JSON, DOCX or XLSX path; existing paths are never replaced')
parser.add_argument('--workspace', type=pathlib.Path, default=pathlib.Path(os.environ.get('LOADSIGHT_WORKSPACE', str(pathlib.Path(__file__).resolve().parents[3] / 'LoadSight'))), help='LoadSight package directory; defaults to LOADSIGHT_WORKSPACE or this repository sibling')
parser.add_argument('--rfi-id', help='Saved RFI identity (rfi-docx only)')
parser.add_argument('--co-id', help='Saved change-order identity (co-docx only)')
parser.add_argument('--catalog', type=pathlib.Path, help='Supplied material snapshot JSON array (catalog-compare only)')
parser.add_argument('--schedule', type=pathlib.Path, help='Column map JSON (schedule-text or schedule-review only)')
parser.add_argument('--map-id', help='Saved map UUID (schedule-saved only)')
args = parser.parse_args()
if args.command != 'schedule-saved' and args.map_id is not None:
    parser.error('--map-id requires schedule-saved')
if args.command not in ['schedule-text', 'schedule-review'] and args.schedule is not None:
    parser.error('--schedule requires schedule-text or schedule-review')
if args.command != 'catalog-compare' and args.catalog is not None:
    parser.error('--catalog requires catalog-compare')
if not (args.workspace / 'Package.swift').is_file():
    parser.error('LoadSightKit source is unavailable; supply --workspace with the package directory.')
if not args.project.is_file():
    parser.error('Input drawing or self-contained project JSON does not exist. Export .loadsight packages to JSON in the app first.')
command = ['swift', 'run', '--package-path', str(args.workspace.resolve()),
           'loadsight', args.command, str(args.project.resolve())]
if args.command == 'schedule-saved':
    if not args.map_id or any(x is not None for x in [args.schedule, args.output, args.request, args.rfi_id, args.co_id, args.catalog]):
        parser.error('schedule-saved requires --map-id and no map/edit/output flags')
    command.append(args.map_id)
elif args.command in ['schedule-text', 'schedule-review']:
    if args.schedule is None or not args.schedule.is_file() or any(x is not None for x in [args.output, args.request, args.rfi_id, args.co_id, args.catalog]):
        parser.error('Schedule extraction requires --schedule mapping.json and no output or edit flags')
    command.append(str(args.schedule.resolve()))
elif args.command == 'catalog-compare':
    if args.catalog is None or not args.catalog.is_file() or any(x is not None for x in [args.output, args.request, args.rfi_id, args.co_id]):
        parser.error('catalog-compare requires --catalog existing-catalog.json and no output or edit flags')
    command.append(str(args.catalog.resolve()))
elif args.command == 'xlsx':
    if args.output is None or args.request is not None or args.rfi_id is not None or args.co_id is not None:
        parser.error('xlsx requires --output new-workbook.xlsx and no edit or record flags')
    if args.output.exists() or args.output.is_symlink():
        parser.error('Output already exists. Choose a new XLSX path.')
    command.append(str(args.output.absolute()))
elif args.command == 'co-docx':
    if not args.co_id or args.output is None or args.request is not None or args.rfi_id is not None:
        parser.error('co-docx requires --co-id and --output new-document.docx')
    if args.output.exists() or args.output.is_symlink():
        parser.error('Output already exists. Choose a new DOCX path.')
    command.extend([args.co_id, str(args.output.absolute())])
elif args.command == 'rfi-docx':
    if not args.rfi_id or args.output is None or args.request is not None or args.co_id is not None:
        parser.error('rfi-docx requires --rfi-id and --output new-document.docx')
    if args.output.exists() or args.output.is_symlink():
        parser.error('Output already exists. Choose a new DOCX path.')
    command.extend([args.rfi_id, str(args.output.absolute())])
elif args.command == 'apply':
    if args.rfi_id is not None or args.co_id is not None:
        parser.error('Record IDs are supported only for their matching DOCX commands')
    if args.request is None or not args.request.is_file() or args.output is None:
        parser.error('apply requires --request existing-request.json and --output new-project.json')
    if args.output.exists() or args.output.is_symlink():
        parser.error('Output already exists. Choose a new path; source projects are never overwritten.')
    command.extend([str(args.request.resolve()), str(args.output.absolute())])
elif args.request is not None or args.output is not None or args.rfi_id is not None or args.co_id is not None:
    parser.error('--request, --output, --rfi-id and --co-id require their matching apply or DOCX command')
raise SystemExit(subprocess.run(command).returncode)
