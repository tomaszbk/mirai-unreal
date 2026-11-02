package mesh

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import unreal "project:plugins/unreal/editor/package"

// What Unreal's skeletal build makes of the corners of a mesh
// description beyond what a static mesh build does: the influences of each
// vertex as the LOD model keeps them, and corners welded into its vertices.

// The influences of each row of the positions as the build gives them to its
// vertices: bones and raw weights, by descending weight, zeros included.
@(private)
Skin_Rows :: struct {first:[]u32,bones,raw:[]u16}

@(private)
Weight :: struct {bone,raw:u16}

// What a project of Unreal sets of the influences the skeletal build keeps,
// in its DefaultEngine.ini: r.GPUSkin.UnlimitedBoneInfluences with its
// threshold, and DefaultBoneInfluenceLimit of the renderer settings.
Skin_Project :: struct {
    unlimited:bool,
    unlimited_threshold:int, // r.GPUSkin.UnlimitedBoneInfluencesThreshold
    influence_limit:int,     // 0: none
}

// The defaults of the engine: no unlimited influences and no limit.
SKIN_PROJECT_DEFAULTS :: Skin_Project{unlimited_threshold=EXTRA_INFLUENCES}

// The skin settings of the project whose content is /Game; the defaults without it.
skin_project_read :: proc(mounts:[]unreal.Source_Mount) -> Skin_Project {
    return skin_project_parse(unreal.project_config_read(mounts,"DefaultEngine.ini"))
}

// The skin settings of the text of a DefaultEngine.ini, in whatever section.
// A PerPlatform value of DefaultBoneInfluenceLimit is not read: its Default
// is that of the desktop.
skin_project_parse :: proc(ini:string) -> (s:Skin_Project) {
    s=SKIN_PROJECT_DEFAULTS
    for line in strings.split_lines(ini,context.temp_allocator) {
        equals:=strings.index_byte(line,'=')
        if equals<0 {continue}
        key,value:=strings.trim_space(line[:equals]),strings.trim_space(line[equals+1:])
        switch {
        case strings.equal_fold(key,"r.GPUSkin.UnlimitedBoneInfluences"):
            s.unlimited=strings.equal_fold(value,"true") || value=="1"
        case strings.equal_fold(key,"r.GPUSkin.UnlimitedBoneInfluencesThreshold"):
            if n,ok:=strconv.parse_int(value);ok && n>=0 {s.unlimited_threshold=n}
        case strings.equal_fold(key,"DefaultBoneInfluenceLimit"):
            // (Default=4,PerPlatform=(...)), or the number alone.
            if at:=strings.index(value,"Default=");at>=0 {
                value=value[at+len("Default="):]
                end:=0
                for end<len(value) && value[end]>='0' && value[end]<='9' {end+=1}
                value=value[:end]
            }
            if n,ok:=strconv.parse_int(value);ok && n>=0 {s.influence_limit=n}
        }
    }
    return
}

// Of the influences of a vertex, how many the build keeps: the limit of the
// asset or of the project, and whether unlimited influences are on.
@(private)
influences_kept :: proc(count:int,weld:Weld_Settings,project:Skin_Project) -> int {
    limit:=weld.influences
    if limit<=0 {limit=project.influence_limit}
    if limit<=0 {limit=LOD_INFLUENCES}
    kept:=min(count,LOD_INFLUENCES,limit)
    if kept>EXTRA_INFLUENCES && !(project.unlimited && kept>project.unlimited_threshold) {kept=EXTRA_INFLUENCES}
    return kept
}

// The first influences of each vertex the build keeps, those of bones the
// reference skeleton has, sorted and renormalized; a vertex without any is
// on the root. ok is false when the weights of a vertex leave their chunk.
@(private)
skin_rows_make :: proc(weights:^Attribute,v:Versions,rows,bones:int,weld:Weld_Settings,project:Skin_Project,scratch:mem.Allocator) -> (s:Skin_Rows,ok:bool) {
    s.first=make([]u32,rows+1,scratch)
    bone_list:=make([dynamic]u16,scratch)
    raw_list:=make([dynamic]u16,scratch)
    for row in 0..<rows {
        s.first[row]=u32(len(bone_list))
        values,inside:=attribute_array(weights,v,row)
        if !inside {return}
        kept:[LOD_INFLUENCES]Weight
        count:=0
        for at in 0..<influences_kept(len(values)/4,weld,project) {
            // The bone in the high 16 bits, the raw weight in the low.
            packed:=u32_at(values,at*4)
            bone:=int(packed>>16)
            if bone>=bones {continue}
            // The weight as a float, then back to a raw unit; under one raw unit is no weight.
            weight:=f32(packed&0xffff)/RAW_WEIGHT_ONE
            raw:=u16(clamp(weight,0,1)*RAW_WEIGHT_ONE+0.5)
            if raw==0 {continue}
            kept[count]={u16(bone),raw}
            count+=1
        }
        if count==0 {
            append(&bone_list,0)
            append(&raw_list,RAW_WEIGHT_ONE)
            continue
        }
        weights_sort(kept[:count])
        weights_normalize(kept[:count])
        for w in kept[:count] {append(&bone_list,w.bone);append(&raw_list,w.raw)}
    }
    s.first[rows]=u32(len(bone_list))
    s.bones,s.raw=bone_list[:],raw_list[:]
    return s,true
}

// Weights by descending weight with an introsort, whose order of equal
// weights decides where the remainders of normalizing go.
@(private)
weights_sort :: proc(w:[]Weight) {
    // Quick sort down to ranges of eight, sorted by selection, and heap sort past a depth of twice the log of the count.
    Range :: struct {min,max:int,depth:u32}
    before :: proc(a,b:Weight) -> bool {return a.raw>b.raw}
    if len(w)<2 {return}
    stack:[32]Range
    stack[0]={0,len(w)-1,u32(math.ln(f32(len(w)))*2)}
    for top:=0;top>=0;top-=1 {
        current:=stack[top]
        for {
            count:=current.max-current.min+1
            if current.depth==0 {
                weights_heap_sort(w[current.min:current.max+1])
                break
            }
            if count<=8 {
                for last:=current.max;last>current.min;last-=1 {
                    at:=current.min
                    for item in current.min+1..=last {if before(w[at],w[item]) {at=item}}
                    w[at],w[last]=w[last],w[at]
                }
                break
            }
            w[current.min+count/2],w[current.min]=w[current.min],w[current.min+count/2]
            low,high:=current.min,current.max+1
            for {
                for {low+=1;if !(low<=current.max && !before(w[current.min],w[low])) {break}}
                for {high-=1;if !(high>current.min && !before(w[high],w[current.min])) {break}}
                if low>high {break}
                w[low],w[high]=w[high],w[low]
            }
            w[current.min],w[high]=w[high],w[current.min]
            current.depth-=1
            if high-1-current.min>=current.max-low {
                if current.min+1<high {stack[top]={current.min,high-1,current.depth};top+=1}
                if current.max>low {current.min=low;continue}
            } else {
                if current.max>low {stack[top]={low,current.max,current.depth};top+=1}
                if current.min+1<high {current.max=high-1;continue}
            }
            break
        }
    }
}

// Heap sort: a heap by the reversed order, popped to the back.
@(private)
weights_heap_sort :: proc(h:[]Weight) {
    after :: proc(a,b:Weight) -> bool {return a.raw<b.raw}
    sift :: proc(h:[]Weight,index,count:int) {
        index:=index
        for index*2+1<count {
            child:=index*2+1
            if child+1<count && !after(h[child],h[child+1]) {child+=1}
            if !after(h[child],h[index]) {break}
            h[index],h[child]=h[child],h[index]
            index=child
        }
    }
    if len(h)<2 {return}
    for index:=(len(h)-2)/2;index>=0;index-=1 {sift(h,index,len(h))}
    for last:=len(h)-1;last>0;last-=1 {
        h[0],h[last]=h[last],h[0]
        sift(h,0,last)
    }
}

// Normalized always: one weight is whole; more scale to add to one, the
// remainder of each carried to the next in descending order.
@(private)
weights_normalize :: proc(w:[]Weight) {
    if len(w)==0 {return}
    if len(w)==1 {w[0].raw=RAW_WEIGHT_ONE;return}
    sum:i64
    resort:=false
    last:=u16(RAW_WEIGHT_ONE)
    for x in w {
        sum+=i64(x.raw)
        resort||=x.raw>last
        last=x.raw
    }
    if sum!=RAW_WEIGHT_ONE {
        correction:i64
        last=RAW_WEIGHT_ONE
        for &x in w {
            scaled:=i64(x.raw)*RAW_WEIGHT_ONE+correction
            x.raw=u16(min(scaled/sum,RAW_WEIGHT_ONE))
            correction=scaled-i64(x.raw)*sum
            resort||=x.raw>last
            last=x.raw
        }
    }
    if resort {weights_sort(w)}
}

// The influences of the rows, without the weights normalizing took to zero.
@(private)
skin_rows_influences :: proc(s:^Skin_Rows,rows:int,allocator:mem.Allocator) -> (first:[]u32,influences:[]Influence) {
    first=make([]u32,rows+1,allocator)
    count:=0
    for raw in s.raw {if raw>0 {count+=1}}
    influences=make([]Influence,count,allocator)
    at:=0
    for row in 0..<rows {
        first[row]=u32(at)
        for i in s.first[row]..<s.first[row+1] {
            if s.raw[i]==0 {continue}
            influences[at]={s.bones[i],f32(s.raw[i])/RAW_WEIGHT_ONE}
            at+=1
        }
    }
    first[rows]=u32(at)
    return
}

// Colors quantized without sRGB, as the skeletal build does; every corner is white when none has a color
// other than black.
@(private)
skin_colors :: proc(t:^Topology,v:Versions,g:^Gather) {
    if len(g.color)==0 {return}
    colors:=attribute_find(&t.instances,.Vector4,"Color")
    colored:=false
    for instance in g.corner_instance {
        if attribute_floats(colors,v,0,int(instance),4)!={0,0,0,1} {colored=true;break}
    }
    for &c,corner in g.color {
        c={255,255,255,255}
        if !colored {continue}
        linear:=attribute_floats(colors,v,0,int(g.corner_instance[corner]),4)
        for i in 0..<4 {
            x:=linear[i]
            if !(x>0) {x=0}
            c[i]=u8(0.5+min(x,1)*255)
        }
    }
}

// In the order of the faces, a corner becomes the first vertex already made
// in its chunk (the material of its section) whose corner overlaps it and is
// equal to it: positions, uvs, tangent basis within the thresholds, color and
// influences the same. A welded corner takes all of that vertex; a triangle
// two of whose corners became one vertex leaves. Corners overlap within the
// position threshold, found over the sort by 0.30x + 0.33y + 0.37z the build
// uses. Returns how many triangles left.
@(private)
corners_weld :: proc(g:^Gather,chunk_of:[]int,skin:^Skin_Rows,weld:Weld_Settings,scratch:mem.Allocator) -> int {
    corners:=len(g.corner_vertex)
    Key :: struct {z:f32,corner:u32}
    keys:=make([]Key,corners,scratch)
    for &key,corner in keys {
        p:=g.positions[g.corner_vertex[corner]]
        key={0.30*p.x+0.33*p.y+0.37*p.z,u32(corner)}
    }
    slice.sort_by(keys,proc(a,b:Key) -> bool {return a.z<b.z || a.z==b.z && a.corner<b.corner})
    rank:=make([]u32,corners,scratch)
    for key,i in keys {rank[key.corner]=u32(i)}
    final:=make([]u32,corners,scratch)
    candidates:=make([dynamic]u32,scratch)
    for corner in 0..<corners {
        final[corner]=u32(corner)
        clear(&candidates)
        at:=int(rank[corner])
        z:=keys[at].z
        p:=g.positions[g.corner_vertex[corner]]
        for j:=at-1;j>=0 && z-keys[j].z<=weld.position;j-=1 {
            other:=keys[j].corner
            if int(other)<corner && within(g.positions[g.corner_vertex[other]],p,weld.position) {append(&candidates,other)}
        }
        for j:=at+1;j<corners && keys[j].z-z<=weld.position;j+=1 {
            other:=keys[j].corner
            if int(other)<corner && within(g.positions[g.corner_vertex[other]],p,weld.position) {append(&candidates,other)}
        }
        slice.sort(candidates[:])
        chunk:=chunk_of[g.triangle_section[corner/3]]
        for other in candidates {
            if final[other]!=other || chunk_of[g.triangle_section[other/3]]!=chunk {continue}
            if corners_equal(g,skin,weld,corner,int(other)) {final[corner]=other;break}
        }
    }
    for corner in 0..<corners {
        from:=int(final[corner])
        if from==corner {continue}
        g.corner_vertex[corner],g.normal[corner],g.tangent[corner]=g.corner_vertex[from],g.normal[from],g.tangent[from]
        g.corner_instance[corner]=g.corner_instance[from]
        if len(g.color)>0 {g.color[corner]=g.color[from]}
        for channel in 0..<g.uv_count {g.uvs[channel][corner]=g.uvs[channel][from]}
    }
    keep:=make([]bool,len(g.triangle_section),scratch)
    for &kept,triangle in keep {
        a,b,c:=final[triangle*3],final[triangle*3+1],final[triangle*3+2]
        kept=a!=b && a!=c && b!=c
    }
    return triangles_keep(g,keep)
}

// Points, normals and UVs are equal when every component is within the threshold.
@(private)
within :: #force_inline proc "contextless" (a,b:[$N]f32,threshold:f32) -> bool {
    for i in 0..<N {if !(abs(a[i]-b[i])<=threshold) {return false}}
    return true
}

// Whether two corners weld into one vertex. TangentY is the binormal the
// build makes of the normal, the tangent and its sign; a
// tangent the import makes later (MikkTSpace) is not yet there to compare.
@(private)
corners_equal :: proc(g:^Gather,skin:^Skin_Rows,weld:Weld_Settings,a,b:int) -> bool {
    if !within(g.positions[g.corner_vertex[a]],g.positions[g.corner_vertex[b]],weld.position) {return false}
    for channel in 0..<g.uv_count {if !within(g.uvs[channel][a],g.uvs[channel][b],weld.uv) {return false}}
    if !within(g.tangent[a].xyz,g.tangent[b].xyz,weld.normal) {return false}
    if !within(binormal(g.normal[a],g.tangent[a]),binormal(g.normal[b],g.tangent[b]),weld.normal) {return false}
    if !within(g.normal[a],g.normal[b],weld.normal) {return false}
    if len(g.color)>0 && g.color[a]!=g.color[b] {return false}
    ra,rb:=g.corner_vertex[a],g.corner_vertex[b]
    if ra==rb {return true}
    first_a,first_b:=skin.first[ra],skin.first[rb]
    count:=skin.first[ra+1]-first_a
    if skin.first[rb+1]-first_b!=count {return false}
    for i in 0..<count {
        if skin.bones[first_a+i]!=skin.bones[first_b+i] || skin.raw[first_a+i]!=skin.raw[first_b+i] {return false}
    }
    return true
}

// The squared length under which a normalized vector is zero.
@(private) SMALL_NUMBER :: 1e-8

@(private)
binormal :: proc(n:[3]f32,t:[4]f32) -> [3]f32 {
    if t.xyz=={} {return {}}
    b:=linalg.cross(n,t.xyz)
    squared:=linalg.dot(b,b)
    if !(squared>=SMALL_NUMBER) {return {}}
    return b/math.sqrt(squared)*t.w
}
