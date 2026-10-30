"""Command line preview; inputs are local UTF-8 files."""
import argparse
from pathlib import Path
from .service import preview


def main(argv=None):
    parser = argparse.ArgumentParser(description='Preview a section merge')
    parser.add_argument('base')
    parser.add_argument('left')
    parser.add_argument('right')
    parser.add_argument('--output', help='write merged preview to this file')
    args = parser.parse_args(argv)
    texts = [Path(name).read_text(encoding='utf-8')
             for name in (args.base, args.left, args.right)]
    document, report = preview(*texts)
    if args.output:
        Path(args.output).write_text(document, encoding='utf-8')
    else:
        print(document, end='')
    print(report)


if __name__ == '__main__':
    main()
