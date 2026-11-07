#######################################################
#                                                     
#  Innovus Command Logging File                     
#  Created on Thu Nov  5 09:52:47 2026                
#                                                     
#######################################################

#@(#)CDS: Innovus v21.16-s078_1 (64bit) 12/07/2022 12:07 (Linux 3.10.0-693.el7.x86_64)
#@(#)CDS: NanoRoute 21.16-s078_1 NR221206-1807/21_16-UB (database version 18.20.600) {superthreading v2.17}
#@(#)CDS: AAE 21.16-s035 (64bit) 12/07/2022 (Linux 3.10.0-693.el7.x86_64)
#@(#)CDS: CTE 21.16-s024_1 () Dec  5 2022 05:41:45 ( )
#@(#)CDS: SYNTECH 21.16-s009_1 () Nov  9 2022 03:47:50 ( )
#@(#)CDS: CPE v21.16-s066
#@(#)CDS: IQuantus/TQuantus 21.1.1-s939 (64bit) Wed Nov 9 09:34:24 PST 2022 (Linux 3.10.0-693.el7.x86_64)

set_global _enable_mmmc_by_default_flow      $CTE::mmmc_default
suppressMessage ENCEXT-2799
restoreDesign /home/s2400012841/chip-fullstack-2026/eda-runs/20261105-window-prefetch-backend/chip/mynpu/pnr/checkpoints/13_finished.enc.dat mynpu_asic_top
setLayerPreference net -isVisible 0
setLayerPreference power -isVisible 0
setLayerPreference powerNet -isVisible 0
setLayerPreference flightLine -isVisible 0
setLayerPreference hinst -isVisible 0
setLayerPreference guide -isVisible 0
setLayerPreference pinObj -isVisible 0
setLayerPreference pinText -isVisible 0
setLayerPreference obstruct -isVisible 0
setLayerPreference stdRow -isVisible 0
setLayerPreference inst -isVisible 1
highlight {0x7efe832bedc0 0x7efe832bee30} -index 11 -color #818cf8
fit
gui_dump_picture /home/s2400012841/chip-fullstack-2026/mynpu-softpe/npu/docs/images/window-prefetch-module-gui.png -format PNG -width 1600 -height 1300
