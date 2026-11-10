; For a fresh exact import of the recorded 20261108 all4 GDS only.
; Uses local OA copies; must not run on shared PDK libraries.
; Run from the recorded signoff workspace with mynpu_ring2000 available.
ok=errset(progn(
src=dbOpenCellViewByType("mynpu_ring2000" "tsmc_c018_sealring_1p6m" "layout" "" "r")
unless(src error("Source ring missing"))
ring=dbCopyCellView(src "mynpu_lab5_exact" "sealring_2000" "layout" nil nil t)
unless(ring error("Ring copy failed"))
unless(ring~>bBox==list(list(-15.0 -15.0) list(1875.0 2005.0)) error("Unexpected source ring dimensions"))
dx=140.0
dy=10.0
foreach(i ring~>instances
 x=xCoord(i~>xy)
 y=yCoord(i~>xy)
 cond(
 (i~>cellName=="tsmc_c018_sealring_corner_1p6m"
  i~>xy=list(x+if(x>0 dx 0.0) y+if(y>0 dy 0.0)))
 (i~>cellName=="tsmc_c018_seal_ring_edge_1p6m"
  if(member(i~>orient list("R0" "MX")) then
    i~>xy=list(x y+if(y>0 dy 0.0))
  else
    i~>xy=list(x+if(x>0 dx 0.0) y)
  ))
 (t error("Unexpected ring master: %s" i~>cellName))
 )
)
foreach(s ring~>shapes
 when(s~>lpp==list("prBoundary" "drawing") s~>bBox=list(list(0.0 0.0) list(2000.0 2000.0)))
)
edge=dbOpenCellViewByType("mynpu_ring2000" "tsmc_c018_seal_ring_edge_1p6m" "layout" "" "r")
for(x 1865 2004
 dbCreateInst(ring edge sprintf(nil "added_bottom_%d" x) list(x 0.0) "MX")
 dbCreateInst(ring edge sprintf(nil "added_top_%d" x) list(x 2000.0) "R0")
)
for(y 1995 2004
 dbCreateInst(ring edge sprintf(nil "added_left_%d" y) list(0.0 y) "R90")
 dbCreateInst(ring edge sprintf(nil "added_right_%d" y) list(2000.0 y) "MXR90")
)
unless(length(ring~>instances)==8044 error("Unexpected adapted ring count"))
dbSave(ring)
cv=dbOpenCellViewByType("mynpu_lab5_exact" "mynpu_asic_top" "layout" "" "a")
unless(cv error("Top missing"))
dbCreateInst(cv ring "i_sealring" list(0.0 0.0) "R0")
pads=setof(i cv~>instances i~>cellName=="PVDD2CDG" && i~>orient=="R0" && yCoord(i~>xy)==0.0)
unless(pads error("Bottom VDDIO pad not found"))
pad=car(pads)
anchor=dbTransformPoint(list(30.0 113.215) pad~>transform)
dbCreateLabel(cv list("METAL3" "pin") anchor "POC" "centerCenter" "R0" "stick" 1.0)
f=outfile("../outputs/sealring_poc.txt")
fprintf(f "ring_bbox=%L instances=%d\n" ring~>bBox length(ring~>instances))
fprintf(f "pad=%s origin=%L orient=%s POC=%L\n" pad~>name pad~>xy pad~>orient anchor)
fprintf(f "top_bbox=%L dbu=%L\n" cv~>bBox cv~>DBUPerUU)
close(f)
dbSave(cv)
dbClose(cv)
dbClose(ring)
dbClose(src)
cv=dbOpenCellViewByType("mynpu_lab5_exact" "B776_POSTVDD2CDG" "layout" "" "a")
shapes=setof(s cv~>shapes s~>layerName=="PIMP" && s~>bBox==list(list(-2.3 52.91) list(52.3 73.795)))
unless(length(shapes)==1 error("Unexpected PIMP patch geometry; inspect the actual IO library"))
car(shapes)~>bBox=list(list(-2.3 52.91) list(52.59 73.795))
dbSave(cv)
dbClose(cv)
printf("LAB5_BUILD_LAYOUT_PASS\n")

) t)
if(ok then exit(0) else exit(1))
