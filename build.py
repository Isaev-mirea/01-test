"""Create a deployable source ZIP without the database, secrets or test output."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parent


def build():
    output = ROOT / "dist" / "shop.zip"
    output.parent.mkdir(exist_ok=True)
    files = [ROOT / "app.py", ROOT / "requirements.txt"]
    for folder in ("data", "templates", "static"):
        files.extend(path for path in (ROOT / folder).rglob("*") if path.is_file())
    with ZipFile(output, "w", ZIP_DEFLATED) as archive:
        for path in sorted(files):
            archive.write(path, path.relative_to(ROOT).as_posix())
    print(f"Build artifact: {output}")
    return output


if __name__ == "__main__":
    build()
