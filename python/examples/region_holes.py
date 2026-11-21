import hongtu as db

layout = db.Layout()
layout.dbu = 0.001
top = layout.create_cell("HOLES_AND_BOOLEAN")
layer = layout.layer(1, 0)
outer = db.Region(db.Box(0, 0, 12000, 8000))
holes = db.Region(db.Box(2000, 2000, 4500, 6000)) + db.Region(db.Box(7500, 2000, 10000, 6000))
ring = outer - holes
top.shapes(layer).insert(ring)
cross = db.Region(db.Box(13000, 3000, 21000, 5000)) + db.Region(db.Box(16000, 0, 18000, 8000))
top.shapes(layout.layer(2, 0)).insert(cross.merged())
top.shapes(layout.layer(3, 0)).insert(cross.sized(400) - cross)
print("Region area in DBU squared:", ring.area())

