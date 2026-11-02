package texture

import "base:intrinsics"

// Inverse of Unreal's row delta (UEDELTA): every tile keeps its first row and
// stores each other row minus the one above, element by element, with a bias
// of 0x80 per byte in 16 and 32 bit elements. Tiles cut a surface by column
// strips of at most 4096 bytes and row bands of about 32768 pixels; how they
// are cut is part of the format. Rows only depend on the row above in the same
// tile, so the inverse runs in place.

@(private="file") MIN_PIXELS_PER_CUT :: 32768
@(private="file") MIN_PIXELS_FOR_ANY_CUT :: 136*136
@(private="file") CUT_STRIDE_BYTES :: 4096
@(private="file") MAX_CUTS :: 512

@(private="file")
cuts_for_rows :: proc(width,height:int) -> (cuts,rows_per_cut:int) {
    pixels:=width*height
    first:=1
    if pixels>MIN_PIXELS_PER_CUT {
        first=pixels/MIN_PIXELS_PER_CUT
        for first>MAX_CUTS {first>>=1}
    }
    rows_per_cut=(height+first-1)/first
    return (height+rows_per_cut-1)/rows_per_cut,rows_per_cut
}

// One surface of width x height pixels of pixel_bytes, rows packed, in place.
delta_inverse_surface :: proc(surface:[]u8,width,height,pixel_bytes,element_bytes:int) {
    if width<=0 || height<=0 || len(surface)<width*height*pixel_bytes {return}
    stride:=width*pixel_bytes
    if width*height<=MIN_PIXELS_FOR_ANY_CUT {
        delta_inverse_tile(surface,stride,0,stride,0,height,element_bytes)
        return
    }
    if stride<=CUT_STRIDE_BYTES {
        cuts,rows:=cuts_for_rows(width,height)
        for cut in 0..<cuts {
            y:=cut*rows
            delta_inverse_tile(surface,stride,0,stride,y,min(rows,height-y),element_bytes)
        }
        return
    }
    parts:=(stride+CUT_STRIDE_BYTES-1)/CUT_STRIDE_BYTES
    part_bytes:=(stride+parts/2)/parts
    part_bytes=(part_bytes+63)&~int(63)
    part_pixels:=part_bytes/pixel_bytes
    parts=(width+part_pixels-1)/part_pixels
    for part in 0..<parts {
        x:=part*part_pixels
        strip:=min(part_pixels,width-x)
        cuts,rows:=cuts_for_rows(strip,height)
        for cut in 0..<cuts {
            y:=cut*rows
            delta_inverse_tile(surface,stride,x*pixel_bytes,strip*pixel_bytes,y,min(rows,height-y),element_bytes)
        }
    }
}

// Each row adds the row above to itself, eight bytes at a time: lanes of
// the element size, each with its top bit as high, add without carries
// between them, plus the bias the other way.
@(private="file")
delta_inverse_tile :: proc(surface:[]u8,stride,x_bytes,width_bytes,y,rows,element_bytes:int) #no_bounds_check {
    if y<0 || x_bytes<0 || rows<=0 || width_bytes<=0 || (y+rows-1)*stride+x_bytes+width_bytes>len(surface) {return}
    high,bias:u64
    switch element_bytes {
    case 1:high,bias=0x8080808080808080,0
    case 2:high,bias=0x8000800080008000,0x7f807f807f807f80
    case 4:high,bias=0x8000000080000000,0x7f7f7f807f7f7f80
    case:return
    }
    whole:=width_bytes&~int(7)
    for row in y+1..<y+rows {
        line:=surface[row*stride+x_bytes:][:width_bytes]
        above:=surface[(row-1)*stride+x_bytes:][:width_bytes]
        for i:=0;i<whole;i+=8 {
            value:=lanes_add(u64(intrinsics.unaligned_load((^u64le)(&line[i]))),u64(intrinsics.unaligned_load((^u64le)(&above[i]))),high)
            if bias!=0 {value=lanes_add(value,bias,high)}
            intrinsics.unaligned_store((^u64le)(&line[i]),u64le(value))
        }
        // A row of whole elements leaves fewer than eight bytes: the rest of a lane word.
        for i:=whole;i+element_bytes<=width_bytes;i+=element_bytes {
            a,b:u64
            for k in 0..<element_bytes {a|=u64(line[i+k])<<uint(8*k);b|=u64(above[i+k])<<uint(8*k)}
            value:=lanes_add(a,b,high)
            if bias!=0 {value=lanes_add(value,bias,high)}
            for k in 0..<element_bytes {line[i+k]=u8(value>>uint(8*k))}
        }
    }
}

@(private="file")
lanes_add :: #force_inline proc "contextless" (a,b,high:u64) -> u64 {
    return ((a&~high)+(b&~high))~((a~b)&high)
}
