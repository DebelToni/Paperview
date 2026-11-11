"""Generate Paperview's opaque app icon. Run with uv --with pillow."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1] / "Paperview/Assets.xcassets"
folder = root / "AppIcon.appiconset"
folder.mkdir(parents=True, exist_ok=True)
image = Image.new("RGB", (1024, 1024), "white")
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((252, 168, 772, 856), radius=42, outline="#202124", width=28)
for y, right in [(340, 658), (432, 658), (524, 580)]:
    draw.line((358, y, right, y), fill="#202124", width=24)
draw.ellipse((493, 583, 691, 738), outline="#ff2d55", width=22)
image.save(folder / "AppIcon.png")
(folder / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
(root / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
