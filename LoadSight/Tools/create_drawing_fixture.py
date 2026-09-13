"""Create independent vector, raster and rotated/cropped pages for ingestion tests."""
from pathlib import Path
from io import BytesIO
from PIL import Image, ImageDraw, ImageFont
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from pypdf import PdfReader, PdfWriter
root=Path(__file__).resolve().parents[1]
fixtures=root/'Tests/LoadSightKitTests/Fixtures'
image=Image.new('RGB',(1400,800),'white')
draw=ImageDraw.Draw(image)
font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',56)
draw.text((100,100),'M202 SUPPLY AIR',fill='black',font=font)
draw.text((100,240),'1200 CFM',fill='black',font=font)
draw.line((100,500,1100,500),fill='black',width=5)
image.save(fixtures/'Scan.png')
buffer=BytesIO()
c=canvas.Canvas(buffer,pagesize=(612,792))
c.setFont('Helvetica',24)
c.drawString(72,720,'M101 MECHANICAL PLAN')
c.setFont('Helvetica',16)
c.drawString(72,670,'RTU-1 1200 CFM')
c.line(72,600,360,600)
c.drawString(72,565,'Known fixture line: 288 page points')
c.showPage()
c.drawImage(ImageReader(image),0,0,width=612,height=350)
c.showPage()
c.setFont('Helvetica',24)
c.drawString(100,600,'M303 ROTATED PLAN')
c.drawString(100,500,'SUPPLY AIR 900 CFM')
c.save()
r=PdfReader(BytesIO(buffer.getvalue()))
w=PdfWriter()
for p in r.pages:w.add_page(p)
w.pages[2].cropbox.lower_left=(50,80)
w.pages[2].cropbox.upper_right=(550,700)
w.pages[2].rotate(90)
with (fixtures/'DrawingIntake.pdf').open('wb') as f:w.write(f)
