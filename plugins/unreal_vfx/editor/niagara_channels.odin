package unreal_vfx_editor

import "core:strings"

// Niagara Data Channels (DataChannelRead / DataChannelWrite) have no GPU data
// channel equivalent in Mirai vfx: game-to-particle births use core.Births
// with Particle_Channel. Only the parameter-prefix helper used by mesh reads
// remains here.

// The name of the variable a parameter carries: In_Position, Out_Color, bOutSuccess.
@(private)
niagara_channel_parameter :: proc(name:string) -> string {
    plain:=name
    for prefix in ([4]string{"In_","Out_","In","Out"}) {
        if strings.has_prefix(plain,prefix) && len(plain)>len(prefix) {plain=plain[len(prefix):];break}
    }
    return plain
}
