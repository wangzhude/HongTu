import hongtu as db
import math

layout = db.Layout()
layout.dbu = 0.001
top = layout.create_cell("PHOTONIC_CRYSTAL")
hole = layout.create_cell("AIR_HOLE")
etch = layout.layer(7, 0)
radius = 130
points = [db.Point(round(radius * math.cos(2 * math.pi * n / 32)),
                   round(radius * math.sin(2 * math.pi * n / 32))) for n in range(32)]
hole.shapes(etch).insert(db.Polygon(points))
pitch = 480
for row in range(17):
    y = round((row - 8) * pitch * math.sqrt(3) / 2)
    for col in range(25):
        if row != 8:
            x = (col - 12) * pitch + (row % 2) * pitch // 2
            top.insert(db.CellInstArray(hole.cell_index(), db.Trans(x, y)))
top.shapes(layout.layer(8, 0)).insert(db.Box(-6500, -3900, 6500, 3900))
print("Triangular lattice with a central line defect; nominal units nm")

