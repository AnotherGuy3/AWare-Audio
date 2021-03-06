package require Tcl 8.4
package require Itcl


# <<<<<<<<<<<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>> #
# <<                                      >> #
# <<     AWExporter Definition BEGIN      >> #
# <<                                      >> #
# <<<<<<<<<<<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>> #

itcl::class AWExporter {
    public variable track
    public variable type
    public variable output
    public variable parent
    public variable progress 0
    variable _result
    variable _regionid
    variable _frameid
    variable _fh
    variable _track_written
    variable _region_written
    variable _headersz 0
    
    # public methods
    method export {}
    
    # private methods
    private method adjusted_frame_value {frame}
    private method frame_to_file {frame}
    private method write_aiff_header {}
    private method write_wav_header {}
    
    constructor {args} {
        if {$args != ""} {
            eval configure $args
        }
    }
}



# export()
#   Dump all of a songs audio frames to a file, and write
#   the file format headers.
#   PARAMS
#       none
#   RETURNS:
#       0 on success, non-zero (probably a message) on failure.
itcl::body AWExporter::export {} {
    if {[catch {open $output w} _fh]} {
        return "Failed to open output file $output" 
    }
    fconfigure $_fh -translation binary    
    
    # leave room for file format headers
    if {[regexp -nocase {wav} $type]} {
        set _headersz $::aw::wav_header_size
    } else {
        set _headersz $::aw::aiff_header_size
    }
    seek $_fh $_headersz start
    
    # begin exporting frames to file
    set _regionid 0
    set _track_written 0
    foreach region [$track regions] {
        set _frameid 0
        set _region_written 0
        foreach frame [$region frames] {
            if {[frame_to_file $frame]} {
                return "Failed to write frame $frame to output file."
            }
            if {$progress} {
                # print progress in 5% intervals
                if { ! [expr int( (double($_track_written) / [$track total_samples]) * 100 ) % 5] } {
                    puts [format "PROGRESS: %d" [expr int( (double($_track_written) / [$track total_samples]) * 100) ]]
                }
            }
            incr _frameid
        }
        incr _regionid
    }
    
    # write header and finish
    if {[regexp -nocase {wav} $type]} {
        set success [write_wav_header]
    } else {
        set success [write_aiff_header]
    }
    close $_fh
    return $success
}


# adjusted_frame_value()
#   convert frame number depending on many variables
#   PARAMS
#       a frame number
#   RETURNS:
#       a number
itcl::body AWExporter::adjusted_frame_value {frame} {
    set diskobj [$parent current_file_object]
    if {[$diskobj previous_frames] == -1} {
        return [expr $frame + [$diskobj offset_frames]]
    }
    return $frame
}


# frame_to_file()
#   export a frame to output file
#   PARAMS
#       a frame number
#   RETURNS:
#       0 on success, non-zero on fail
itcl::body AWExporter::frame_to_file {frame} {
    set song [$track parent]
    set diskobj [$parent current_file_object]
    set region [lindex [$track regions] $_regionid]
    set bits [$song bits]
    set rate [$song rate]
    set framesz $::aw::block_size
    set frameloc 0
    set audioloc 0
    
    # frame exists on another disk/file?
    while {[adjusted_frame_value $frame] > [$diskobj max_frames] || \
                [adjusted_frame_value $frame] < 0} {
        if {[$parent get_file_for_frame $frame]} {
            return -1
        } 
        # reset disk object after getting new file
        set diskobj [$parent current_file_object]           
    }
    
    # adjust for differences between 24 bit and 16 bit frames
    if {[$song bits] == 24} {
        set framesz [expr $framesz - $::aw::audio_24bit_offset]
    }
    
    # this offset sends us beyond the bounds of the frame?
	# adjust offset and skip this frame.
	if {[expr [$region offset_samples] * ($bits/8)] > $framesz} {
	    $region offset_samples [expr [$region offset_samples] - $framesz/($bits/8)]
	    return 0
	}
    
    # determine location this songs audio frames on the disk/file
	if {[$diskobj index] == 0} {
		if {[$parent type] == "AW16G"} {
			set audioloc [expr ([llength [$parent songs]] * $::awg::songblock_size) + $::awg::songblock_location]
		} else {
			set audioloc [expr ([llength [$parent songs]] * $::aw::songblock_size) + $::aw::songblock_location]
		}
	} else {
		set audioloc $::aw::songblock_location
	}
	
	# determine starting location of this frame
	if {[$parent type] == "AW16G" && [[$parent current_file_object] index] == 0} {
		set frameloc [expr [$song location] + [adjusted_frame_value $frame] * $::aw::block_size]
	} else {
 	    set frameloc [expr $audioloc + ([adjusted_frame_value $frame] * $::aw::block_size)]
	}
	
	# adjustments for the first frame in a region
	if {$_frameid == 0} {
	
	    # adjust for offset samples
		if {[$region offset_samples] < 24} {
			set framesz [expr $framesz - $::aw::audio_firstblock_offset]
			set frameloc [expr $frameloc + $::aw::audio_firstblock_offset]
        } else {
            set framesz [expr $framesz - ([$region offset_samples] * ($bits/8))]
			set frameloc [expr $frameloc + ([$region offset_samples] * ($bits/8))]
		}
		
		# pad beginning of region audio with zeros (only for first frame)?
		if {[$region start_sample] > $_track_written} {
		    seek $_fh [expr ([$region start_sample] - $_track_written) * ($bits/8) ] current
			set _track_written [expr $_track_written + ([$region start_sample] - $_track_written)]
		}
		
		# region start is less than track samples written?
		# rare, but we must rewind in the file and adjust samples accordingly.
		if {[$region start_sample] < $_track_written} {
		    seek $_fh [expr $_headersz + ([$region start_sample] * ($bits/8))] start
			set _track_written [$region start_sample]
		}
	}
		
    # For the last frame only, do not export more of this frame than the region has declared.
    if {$_frameid == [expr [$region frame_count] - 1]} {
        if {[expr $framesz / ($bits/8) + $_region_written] > [$region total_samples]} {
            set framesz [expr ([$region total_samples] - $_region_written) * ($bits/8)] 
        }
    }   
    
    # read block of data into buffer and dump to file
	if {$framesz > 0} {
		# ensure we have an even number of samples for this bit depth.
		# add a few zeros if we need to...
		set framesz [expr $framesz + ($framesz % ($bits/8))]
		
		seek [$parent current_handle] $frameloc start
		set buffer [read [$parent current_handle] $framesz]
		
		# swap byte order to little-endian for WAV format.
		# this really slows things down. oh well.
		if {[regexp -nocase {wav} $type]} {
		    if {$bits == 24} {
		        set buffer [regsub -all {(.)(.)(.)} $buffer {\3\2\1}]
		    } else {
		        set buffer [regsub -all {(.)(.)} $buffer {\2\1}]
		    }
		}
		
		puts -nonewline $_fh $buffer
		set _track_written [expr $_track_written + $framesz/($bits/8)]
		set _region_written [expr $_region_written + $framesz/($bits/8)]
	}

    return 0    
}


# write_aiff_header()
#   Write the AIFF header to the start of the file after all samples have been
#   written.
#   PARAMS
#       
#   RETURNS:
#       0 on success, non-zero on fail
itcl::body AWExporter::write_aiff_header {} {
    set channels 1
    set frames [expr $_track_written/$channels]
    set song [$track parent]
    set bits [$song bits]
    set rate [$song rate]
    set bytes [expr $_track_written * ($bits/8)]
    set rates(44100) [list 0x40 0x0E 0xAC 0x44 0x00 0x00 0x00 0x00 0x00 0x00]
    set rates(48000) [list 0x40 0x0E 0xBB 0x80 0x00 0x00 0x00 0x00 0x00 0x00]
    
    # rewind the file
    seek $_fh 0 start
    puts -nonewline $_fh "FORM"
    puts -nonewline $_fh [binary format I [expr $bytes + ($_headersz - 8)]]
    
    puts -nonewline $_fh "AIFF"
    
    # chunksize
    puts -nonewline $_fh "COMM"
    puts -nonewline $_fh [binary format I 18]
    
    # channels (only mono is supported)
    puts -nonewline $_fh [binary format S 1]
    
    # frame count
    puts -nonewline $_fh [binary format I $frames]
    
    # bit depth
    puts -nonewline $_fh [binary format S $bits]
    
    # sample rates
    if {$rate == 44100} {
        puts -nonewline $_fh [binary format c* $rates(44100)]
    } else {
        puts -nonewline $_fh [binary format c* $rates(48000)]
    }
    
    # chunk size
    puts -nonewline $_fh "SSND"
    puts -nonewline $_fh [binary format I [expr $bytes + 8]]
    
    # offset 
    puts -nonewline $_fh [binary format I 0]
    
    # block size
    puts -nonewline $_fh [binary format I 0]
    
    return 0
}


# write_wav_header()
#   Write the WAV header to the start of the file after all samples have been
#   written.
#   PARAMS
#       
#   RETURNS:
#       0 on success, non-zero on fail
itcl::body AWExporter::write_wav_header {} {
    set channels 1
    set frames [expr $_track_written/$channels]
    set song [$track parent]
    set bits [$song bits]
    set rate [$song rate]
    set bytes [expr $_track_written * ($bits/8)]
    set rates(44100) [list 0x40 0x0E 0xAC 0x44 0x00 0x00 0x00 0x00 0x00 0x00]
    set rates(48000) [list 0x40 0x0E 0xBB 0x80 0x00 0x00 0x00 0x00 0x00 0x00]
    
    # rewind the file
    seek $_fh 0 start
    
    # initial header
    puts -nonewline $_fh "RIFF"
    puts -nonewline $_fh [binary format i [expr 32 + ($_track_written * $channels * ($bits/8))]]
    puts -nonewline $_fh "WAVE"
    puts -nonewline $_fh "fmt "
    
    # chunksize
    puts -nonewline $_fh [binary format i 16]
    
    # specify PCM format
    puts -nonewline $_fh [binary format s 1]
    
    # channels
    puts -nonewline $_fh [binary format s $channels]
    
    # sample rate
    puts -nonewline $_fh [binary format i $rate]
    
    # byte rate
    puts -nonewline $_fh [binary format i [expr $rate * $channels * ($bits/8)]]
    
    # block align
    puts -nonewline $_fh [binary format s [expr $channels * ($bits/8)]]
    
    # bit depth
    puts -nonewline $_fh [binary format s $bits]
    
    puts -nonewline $_fh "data"
    puts -nonewline $_fh [binary format i [expr $_track_written * $channels * ($bits/8)]]

    return 0
}



####  AWExporter Definition END  ####

