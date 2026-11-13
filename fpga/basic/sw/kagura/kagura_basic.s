; KAGURA-6502 BASIC: top-level assembly file for mist64/msbasic.
; Same include order as third_party/msbasic/msbasic.s (unmodified upstream), with
; the platform selected here instead of by a -D option, so that no upstream file
; has to change. Build: fpga/basic/sw/build_sw.sh (ca65/ld65 from cc65 V2.19).

.debuginfo +

.setcpu "6502"                  ; the interpreter uses NMOS 6502 instructions only
.macpack longbranch

.include "defines_kagura.s"     ; KAGURA config (must precede defines.s: CONFIG cascade)
.include "defines.s"
.include "macros.s"
.include "zeropage.s"

.include "header.s"
.include "token.s"
.include "error.s"
.include "message.s"
.include "memory.s"
.include "program.s"
.include "flow1.s"
.include "loadsave.s"
.include "flow2.s"
.include "misc1.s"
.include "print.s"
.include "input.s"
.include "eval.s"
.include "var.s"
.include "array.s"
.include "misc2.s"
.include "string.s"
.include "misc3.s"
.include "poke.s"
.include "float.s"
.include "chrget.s"
.include "rnd.s"
.include "trig.s"
.include "init.s"
.include "extra.s"
.include "kagura_extra.s"
