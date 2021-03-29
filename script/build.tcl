# *************************************************************************
#
# Copyright 2020 Xilinx, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# *************************************************************************

# Procedure definitions
proc write_questa_sim {} {
    global script_dir
    global sim_dir
    global top_build_dir
    global top
    global generic

    set param_decls {}
    foreach p $generic {lappend param_decls "localparam $p;"}

    set fp [open "${top_build_dir}/questa_sim.do" w]
    puts $fp "set top $top"
    puts $fp "set top_build_dir $top_build_dir"
    puts $fp "set sim_dir $sim_dir"
    puts $fp {set fp [open ${top_build_dir}/${top}.f r]}
    puts $fp "foreach path \[read \$fp\] {"
    puts $fp {    if {[string equal [file extension $path] ".vhd"]} {vcom +acc +incdir+${top_build_dir} $path} else {vlog -sv +acc +incdir+${top_build_dir} $path}}
    puts $fp "}"
    puts $fp {close $fp}
    puts $fp {vsim -sv_root ${sim_dir}/dpi -sv_lib tap -L xpm -L unisims_ver -L axi_crossbar_v2_1_23 -L generic_baseblocks_v2_1_0 -L axis_register_slice_v1_1_22 -L axis_infrastructure_v1_1_0 -L axi_register_slice_v2_1_22 -L ecc_v2_0_13 ${top}_tb glbl}
    puts $fp {run -all}
    close $fp

    set fp [open "${top_build_dir}/sim_config.vh" w]
    foreach p $param_decls {
        puts $fp $p
    }
    close $fp

    set run_script "${top_build_dir}/run_questa_sim.sh"
    set fp [open $run_script w]
    set questa_dir {$(dirname $(which vsim))/..}
    puts $fp "#! /bin/bash"
    puts $fp {if [ $# -ne 1 ]; then}
    puts $fp {    echo "Usage: run_questa_sim.sh SIMLIB_INI"}
    puts $fp {    exit 1}
    puts $fp {fi}
    puts $fp "questa_dir=\"$questa_dir\""
    puts $fp "simlib_ini=\$1"
    foreach p $generic {
        puts $fp $p
    }
    puts $fp "pushd ${top_build_dir} > /dev/null"
    puts $fp {echo "Compiling DPI libraries..."}
    puts $fp "gcc -shared -fPIC -I\${questa_dir}/include -o ${sim_dir}/dpi/tap.so ${sim_dir}/dpi/tap.c"
    puts $fp {echo "Setting up virtual adapters..."}
    puts $fp "${script_dir}/setup_sim.sh \$NUM_PHYS_FUNC \$NUM_CMAC_PORT"
    puts $fp {echo "Launching QuestaSim..."}
    puts $fp "vsim -c -64 -modelsimini \${simlib_ini} -do questa_sim.do"
    puts $fp {echo "Cleaning up virtual adapters..."}
    puts $fp "${script_dir}/clean_sim.sh \$NUM_PHYS_FUNC \$NUM_CMAC_PORT"
    puts $fp "popd > /dev/null"
    close $fp
    file attributes $run_script -permissions "a+x"

    return $run_script
}
#######################

# Vivado version check
set VIVADO_VERSION "2020.2"
if {![string equal [version -short] $VIVADO_VERSION]} {
    puts "OpenNIC shell requires Vivado version $VIVADO_VERSION"
    exit
}

# Directory variables
set root_dir [file normalize ..]
set constr_dir ${root_dir}/constr
set plugin_dir ${root_dir}/plugin
set script_dir ${root_dir}/script
set src_dir ${root_dir}/src
set sim_dir ${root_dir}/sim

# Build options
#   board_repo   Path to the Xilinx board store repository
#   board        Board name
#   tag          Tag to identify the build
#   overwrite    Overwrite existing build results
#   jobs         Number of jobs for synthesis and implementation
#   synth_ip     Synthesize IPs before creating design project
#   impl         Run implementation after creating design project
#   post_impl    Perform post implementation actions
#   sdnet        Path to SDNet executable
#   sim          Switch to simulation build
#   user_plugin  Path to the user plugin repo
#
# Design parameters
#   build_timestamp  Timestamp to identify the build
#   min_pkt_len      Minimum packet length
#   max_pkt_len      Maximum packet length
#   use_phys_func    Include H2C and C2H AXI-stream interfaces (0 or 1)
#   num_phys_func    Number of PCI-e physical functions (1 to 4)
#   num_queue        Number of QDMA queues (1 to 2048)
#   num_cmac_port    Number of CMAC ports (1 or 2)
array set build_options {
    -board_repo  ""
    -board       au250
    -tag         ""
    -overwrite   0
    -jobs        8
    -synth_ip    1
    -impl        0
    -post_impl   0
    -sdnet       ""
    -sim         0
    -user_plugin ""
}
set build_opitons(-user_plugin) ${plugin_dir}/p2p

array set design_params {
    -build_timestamp  0
    -min_pkt_len      64
    -max_pkt_len      1514
    -use_phys_func    1
    -num_phys_func    1
    -num_queue        2048
    -num_cmac_port    1
}
set design_params(-build_timestamp) [clock format [clock seconds] -format %m%d%H%M]

# Expect arguments in the form of `-argument value`
for {set i 0} {$i < $argc} {incr i 2} {
    set arg [lindex $argv $i]
    set val [lindex $argv [expr $i+1]]
    if {[info exists build_options($arg)]} {
        set build_options($arg) $val
        puts "Set build option $arg to $val"
    } elseif {[info exists design_params($arg)]} {
        set design_params($arg) $val
        puts "Set design parameter $arg to $val"
    } else {
        puts "Skip unknown argument $arg and its value $val"
    }
}

# Settings based on defaults or passed in values
foreach {key value} [array get build_options] {
    set [string range $key 1 end] $value
}
foreach {key value} [array get design_params] {
    set [string range $key 1 end] $value
}

# Sanity check
set synth_ip  [expr {!$sim && $synth_ip}]
set impl      [expr {!$sim && $impl}]
set post_impl [expr {!$sim && $post_impl}]

if {$min_pkt_len < 64 || $min_pkt_len > 256} {
    puts "Invalid value for -min_pkt_len: allowed range is \[64, 256\]"
    exit
}
if {$max_pkt_len < 256 || $max_pkt_len > 9600} {
    puts "Invalid value for -max_pkt_len: allowed range is \[256, 9600\]"
    exit
}
if {$num_queue < 1 || $num_queue > 2048} {
    puts "Invalid value for -num_queue: allowed range is \[1, 2048\]"
    exit
}
if {$num_phys_func < 0 || $num_phys_func > 4} {
    puts "Invalid value for -num_phys_func: allowed range is \[0, 4\]"
    exit
}
if {$num_cmac_port != 1 && $num_cmac_port != 2} {
    puts "Invalid value for -num_cmac_port: allowed values are 1 and 2"
    exit
}

source ${script_dir}/board_settings/${board}.tcl

# Set build directory and dump the current design parameters
set top open_nic_shell
set build_name ${board}
if {![string equal $tag ""]} {
    set build_name ${build_name}_${tag}
}
if {$sim} {
    set build_name sim_${build_name}
}
set build_dir [file normalize ${root_dir}/build/${build_name}]
if {[file exists $build_dir]} {
    puts "Found existing build directory $build_dir"
    puts "  1. Update existing build directory (default)"
    puts "  2. Delete existing build directory and create a new one"
    puts "  3. Exit"
    puts -nonewline {Choose an option: }
    gets stdin ans
    if {[string equal $ans "2"]} {
        file delete -force $build_dir
        puts "Deleted existing build directory $build_dir"
    } elseif {[string equal $ans "3"]} {
        puts "Build directory existed. Try to specify a different design tag"
        exit
    }
} else {
    file mkdir $build_dir
}
set fp [open "${build_dir}/DESIGN_PARAMETERS" w]
foreach {param val} [array get design_params] {
    puts $fp "$param $val"
}
close $fp

# Update the board store
if {[string equal $board_repo ""]} {
    xhub::refresh_catalog [xhub::get_xstores xilinx_board_store]
} else {
    set_param board.repoPaths $board_repo
}

# Enumerate modules
foreach name [glob -tails -directory ${src_dir} -type d *] {
    if {![string equal $name "shell"]} {
        dict append module_dict $name "${src_dir}/${name}"
    }
}

# Create/open Manage IP project
set ip_build_dir ${build_dir}/vivado_ip
if {![file exists ${ip_build_dir}/manage_ip/]} {
    puts "INFO: \[Manage IP\] Creating Manage IP project..."
    create_project -force manage_ip ${ip_build_dir}/manage_ip -part $part -ip
    if {![string equal $board_part ""]} {
        set_property BOARD_PART $board_part [current_project]
    }
    set_property simulator_language verilog [current_project]
} else {
    puts "INFO: \[Manage IP\] Opening existing Manage IP project..."
    open_project -quiet ${ip_build_dir}/manage_ip/manage_ip.xpr
}

# Run synthesis for each IP
set ip_dict [dict create]
dict for {module module_dir} $module_dict {
    set ip_tcl_dir ${module_dir}/vivado_ip

    # Check the existence of "$ip_tcl_dir" and "${ip_tcl_dir}/vivado_ip.tcl"
    if {![file exists $ip_tcl_dir] || ![file exists ${ip_tcl_dir}/vivado_ip.tcl]} {
        puts "INFO: \[$module\] Nothing to build"
        continue
    }

    # Expect the variable "$ips" defined in "vivado_ip.tcl"
    source ${ip_tcl_dir}/vivado_ip.tcl
    if {![info exists ips]} {
        puts "INFO: \[$module\] Nothing to build"
        continue
    }

    foreach ip $ips {
        # Pre-save IP name and its build directory to a global dictionary
        dict append ip_dict $ip ${ip_build_dir}/${ip}

        # Remove IP that does not exists in the project, which may have been
        # deleted by the user and needs to be regnerated
        if {[string equal [get_ips -quiet $ip] ""]} {
            export_ip_user_files -of_objects [get_files ${ip_build_dir}/${ip}/${ip}.xci] -no_script -reset -force -quiet
            remove_files -quiet [get_files ${ip_build_dir}/${ip}/${ip}.xci]
            file delete -force ${ip_build_dir}/${ip}
        }

        # Build the IPs only when
        # - No DCP genereated (for implementation), or
        # - No simulation wrapper genereated (for simulation), or
        # - "$overwrite" option is nonzero
        if {$sim} {
            set cached [file exists ${ip_build_dir}/${ip}/sim]
        } else {
            set cached [file exists ${ip_build_dir}/${ip}/${ip}.dcp]
        }
        if {$cached && !$overwrite} {
            puts "INFO: \[$ip\] Use existing IP build (overwrite=0)"
            continue
        }
        if {$cached} {
            puts "INFO: \[$ip\] Found existing IP build, deleting... (overwrite=1)"
            file delete -force ${ip_build_dir}/${ip}
        }

        # Rule for IP scripts
        # - Source "${ip}_${board}.tcl" if exists
        # - Else, source "${ip}.tcl" if exists
        # - Otherwise, skip this IP as it may be specific for certain board target
        if {[file exists "${ip_tcl_dir}/${ip}_${board}.tcl"]} {
            source ${ip_tcl_dir}/${ip}_${board}.tcl
        } elseif {[file exists "${ip_tcl_dir}/${ip}.tcl"]} {
            source ${ip_tcl_dir}/${ip}.tcl
        } else {
            continue
        }

        upgrade_ip [get_ips $ip]

        if {$sim} {
            generate_target simulation [get_ips $ip]
        } else {
            generate_target synthesis [get_ips $ip]
        }

        # Run out-of-context IP synthesis
        if {$synth_ip} {
            create_ip_run [get_ips $ip]
            launch_runs ${ip}_synth_1
            wait_on_run ${ip}_synth_1
        }
    }
}

# Close the Manage IP project
close_project

# Setup build directory for the design
set top_build_dir ${build_dir}/${top}

if {[file exists $top_build_dir] && !$overwrite} {
    puts "INFO: \[$top\] Use existing build (overwrite=0)"
    return
}
if {[file exists $top_build_dir]} {
    puts "INFO: \[$top\] Found existing build, deleting... (overwrite=1)"
    file delete -force $top_build_dir
}

# For simulation build, we only generate a list file under `top_build_dir`,
# which specifies the files needed to include in simulation.  The file can be
# then read into different simulators.

if {$sim} {
    set sim_files {}
    lappend sim_files "[file dirname [exec which vivado]]/../data/verilog/src/glbl.v"
} else {
    create_project -force $top $top_build_dir -part $part
    if {![string equal $board_part ""]} {
        set_property BOARD_PART $board_part [current_project]
    }
    set_property target_language verilog [current_project]

    # Marco to enable conditional compilation at Verilog level
    set verilog_define "__synthesis__ __${board}__"
    if {$zynq_family} {
        append verilog_define " " "__zynq_family__"
    }
    set_property verilog_define $verilog_define [current_fileset]
}

# Read IPs from finished IP runs
# - Some IPs are board-specific and will be ignored for other board targets
dict for {ip ip_dir} $ip_dict {
    if {$sim} {
        set sim_files [concat $sim_files [glob -nocomplain -directory ${ip_dir}/sim "${ip}.{v,sv,vhd}"]]
    } else {
        read_ip -quiet ${ip_dir}/${ip}.xci
    }
}

# Read user plugin files
set include_dirs [get_property include_dirs [current_fileset]]
foreach freq [list 250mhz 322mhz] {
    set box "box_$freq"
    set box_plugin ${user_plugin}/${box}
    set default_box_plugin ${plugin_dir}/p2p/${box}
    
    if {[file exists $box_plugin] && [file exists ${user_plugin}/build_${box}.tcl]} {
        source ${box_plugin}/${box}_axi_crossbar.tcl
        read_verilog -quiet ${box_plugin}/${box}_address_map.v
        lappend include_dirs $box_plugin
    } else {
        source ${default_box_plugin}/${box}_axi_crossbar.tcl
        read_verilog -quiet ${default_box_plugin}/${box}_address_map.v
        lappend include_dirs $default_box_plugin
    }

    cd $user_plugin
    source build_${box}.tcl
    cd $script_dir
}
set_property include_dirs $include_dirs [current_fileset]

# Read the source files from each module
# - First, source "build.tcl" if it is defined under `module_dir`
# - Then, read all the RTL files under `module_dir` (excluding sub-directories)
dict for {module module_dir} $module_dict {
    if {[file exists ${module_dir}/build.tcl]} {
        cd $module_dir
        source build.tcl
        cd $script_dir
    }

    if {$sim} {
        set sim_files [concat $sim_files [glob -nocomplain -directory $module_dir "*.{v,sv,vhd}"]]
    } else {
        read_verilog -quiet [glob -nocomplain -directory $module_dir "*.{v,vh}"]
        read_verilog -quiet -sv [glob -nocomplain -directory $module_dir "*.sv"]
        read_vhdl -quiet [glob -nocomplain -directory $module_dir "*.vhd"]
    }
}

# Read top-level source files
if {$sim} {
    set sim_files [concat $sim_files [glob -nocomplain -directory $src_dir "*.{v,sv,vhd}"]]
} else {
    read_verilog -quiet [glob -nocomplain -directory $src_dir "*.{v,vh}"]
    read_verilog -quiet -sv [glob -nocomplain -directory $src_dir "*.sv"]
    read_vhdl -quiet [glob -nocomplain -directory $src_dir "*.vhd"]
}

# Set vivado generic
set design_params(-build_timestamp) "32'h$design_params(-build_timestamp)"
set generic ""
foreach {key value} [array get design_params] {
    set p [string toupper [string range $key 1 end]]
    lappend generic "$p=$value"
}
set_property -name generic -value $generic -object [current_fileset]

# For simulation build, write out the file list and exit
if {$sim} {
    set fp [open "${sim_dir}/${top}_tb.f" r]
    set tb_files [read $fp]
    close $fp

    file mkdir $top_build_dir
    set fp [open "${top_build_dir}/${top}.f" w]
    foreach path $sim_files {
        puts $fp $path
    }
    foreach path $tb_files {
        puts $fp "${sim_dir}/${path}"
    }
    close $fp

    set run_script [write_questa_sim]

    puts "=========="
    puts "Simulation Build Done"
    puts "To run simulation, run the script \"$run_script\""
    puts "=========="
    exit
}

set_property top $top [get_property srcset [current_run]]

# Read constraint files
read_xdc -unmanaged ${constr_dir}/${board}/pins.xdc
read_xdc -unmanaged ${constr_dir}/${board}/timing.xdc
read_xdc ${constr_dir}/${board}/general.xdc

# Implement design
if {$impl} {
    update_compile_order -fileset sources_1
    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_on_run impl_1
}

# TODO: check implementation results before starting post steps

if {$post_impl} {
    if {$zynq_family} {
        set sdk_dir ${top_build_dir}/${top}.sdk
        file mkdir $sdk_dir
        write_hw_platform -fixed -force -include_bit -file ${sdk_dir}/${top}.xsa
    } else {
        set interface SPIx4
        set start_address 0x01002000
        set bit_file ${top_build_dir}/${top}.runs/impl_1/${top}.bit
        set mcs_file ${top_build_dir}/${top}.runs/impl_1/${top}.mcs

        write_cfgmem -format mcs -size 128 -interface $interface -loadbit "up $start_address $bit_file" -file "$mcs_file"
    }
}