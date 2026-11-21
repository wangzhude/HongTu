import hongtu as db

layout = db.Layout()
layout.dbu = 0.001
top = layout.create_cell("COMB_TEST")
left = db.Region(db.Box(0, 0, 600, 13000))
right = db.Region(db.Box(12400, 0, 13000, 13000))
for n in range(12):
    y = n * 1000 + 300
    left += db.Region(db.Box(600, y, 10500, y + 250))
    right += db.Region(db.Box(2500, y + 500, 12400, y + 750))
top.shapes(layout.layer(1, 0)).insert(left.merged())
top.shapes(layout.layer(2, 0)).insert(right.merged())
print("Interdigitated comb geometry with explicit gap")
