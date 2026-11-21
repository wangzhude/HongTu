import hongtu as db

layout = db.Layout()
layout.dbu = 0.001
top = layout.create_cell("INTERCONNECT")
via = layout.create_cell("VIA_DEMO")
m1 = layout.layer(1, 0)
m2 = layout.layer(2, 0)
cut = layout.layer(10, 0)
via.shapes(cut).insert(db.Box(-120, -120, 120, 120))
via.shapes(m1).insert(db.Box(-240, -240, 240, 240))
via.shapes(m2).insert(db.Box(-240, -240, 240, 240))
for n in range(6):
    y = n * 1500
    top.shapes(m1).insert(db.Path([db.Point(0, y), db.Point(6000, y), db.Point(6000, y + 600)], 300, 80, 170, False))
    top.shapes(m2).insert(db.Path([db.Point(6000, y), db.Point(9500, y)], 400))
    top.insert(db.CellInstArray(via.cell_index(), db.Trans(6000, y)))
print("Demo routing and via geometry; no foundry PDK claim")

