import hongtu as db

layout = db.Layout()
layout.dbu = 0.001
top = layout.create_cell("ARRAY_TOP")
pixel = layout.create_cell("PIXEL")
metal = layout.layer(1, 0)
pixel.shapes(metal).insert(db.Box(0, 0, 1600, 800))
pixel.shapes(metal).insert(db.Path([db.Point(0, 1200), db.Point(800, 1200), db.Point(800, 1900)], 180))
top.insert(db.CellInstArray(pixel.cell_index(), db.Trans(1000, 2000),
                           db.Vector(2400, 0), db.Vector(0, 2800), 4, 3))
top.insert(db.CellInstArray(pixel.cell_index(), db.ICplxTrans(1.5, 90, True, 15000, 4000)))
print("Hierarchy: 2 cells, 12 array instances and one transformed instance")

