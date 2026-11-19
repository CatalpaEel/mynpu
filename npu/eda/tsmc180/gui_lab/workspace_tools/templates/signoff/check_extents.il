cv=dbOpenCellViewByType("mynpu_lab5_exact" "mynpu_asic_top" "layout" "" "r")
f=outfile("../outputs/extents_diagnostic.txt")
fprintf(f "top=%L\n" cv~>bBox)
foreach(s cv~>shapes
 when(caadr(s~>bBox)>1965.0001 || cadadr(s~>bBox)>1965.0001
  fprintf(f "shape type=%L layer=%L purpose=%L bbox=%L text=%L\n" s~>objType s~>layerName s~>purpose s~>bBox s~>theLabel)
 )
)
foreach(i cv~>instances
 when(caadr(i~>bBox)>1965.0001 || cadadr(i~>bBox)>1965.0001
  fprintf(f "inst=%s cell=%s bbox=%L\n" i~>name i~>cellName i~>bBox)
 )
)
close(f)
dbClose(cv)
exit()
