set run_root [file normalize [file join [file dirname [info script]] ..]]
source $run_root/scripts/flow_paths.tcl
set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
create_library_set -name lib_tt_io -timing [list $stdroot/Front_End/timing_power_noise/NLDM/tcb018gbwp7t_270a/tcb018gbwp7ttc.lib $macro/RA1SHD_2048x32M8_tt_1p8_25C_syn.lib $pdk/tpd018nv_280a/TSMCHOME/digital/Front_End/timing_power_noise/NLDM/tpd018nv_280a/tpd018nvtc.lib]
create_rc_corner -name rc_tt -T 25 -cap_table $stdroot/Back_End/lef/tcb018gbwp7t_270a/techfiles/captable/t018lo_1p6m_typical.captable
create_delay_corner -name delay_tt_io -library_set lib_tt_io -rc_corner rc_tt
create_constraint_mode -name func -sdc_files $run_root/scripts/chip.sdc
create_analysis_view -name func_tt_io -constraint_mode func -delay_corner delay_tt_io
set_analysis_view -setup func_tt_io -hold func_tt_io
