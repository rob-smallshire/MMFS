\\ SPItFIRE MMC DEVICE
\\
\\ SPItFIRE is a multi-device SPI adapter for the Master Compact's
\\ Mouse/Joystick port (User VIA port B). The MMC signals are as for the
\\ standard User Port interface (MOSI=PB0, SCK=PB1 wired to CB1, MISO=CB2)
\\ but PB2-PB4 drive the address inputs of a 74HC138, whose outputs are
\\ the chip selects of several SPI devices. The SD card is on output Y2.
\\
\\ Based on MMC_UserPort.asm (non-turbo). Differences:
\\   - PB2-PB4 are outputs, and every write to iorb% carries the SD card's
\\     select code, so the card stays selected throughout a transaction.
\\   - UP_WriteByte keeps PB2-PB4 constant (the User Port version lets
\\     the unsent data bits ripple across PB2-PB7).
\\   - MMC_DEVICE_RESET selects the card only after SCK is high, and
\\     MMC_DEVICE_DESELECT releases the bus for the other devices. It is
\\     called from ResetLEDS, which ends every card operation and every
\\     error report, and from MMC_END. (MMC_END alone is not enough: it
\\     ends a zero page save, not a card operation, and many reads
\\     follow MMC_BEGIN2, which has already called it.)
\\
\\ Bulk reads use shift register mode 2, exactly as the User Port driver.
\\ Writes are bit-banged; the TurboMMC mode 6 write path is not usable
\\ because it needs external buffers switched by PB2-PB4.

\ User VIA registers
iorb%=_VIA_BASE
ddrb%=_VIA_BASE + &02
sr%  =_VIA_BASE + &0A
acr% =_VIA_BASE + &0B
ifr% =_VIA_BASE + &0D
ier% =_VIA_BASE + &0E

   ddrmask = &1F \\ 0001 1111   PB0-PB4 are outputs
   msbits  = &08 \\ 0000 1000   74HC138 Y2 (A1=1) selects the SD card
   nosel   = &00 \\ 0000 0000   74HC138 Y0 selects no device


    \\ **** Send Data Token to card ****
.MMC_SendingData
{
    JSR MMC_16Clocks
    LDA #&FE
    \\ Fall through to UP_WriteByte
}

    \\ Write byte (User Port)
    \\ Ignore byte in
    \\ Preserves X and Y
.UP_WriteByte
{
    FOR N, 0, 7
        ASL A                \\ Next data bit (MSB first) into C
        PHA
        LDA #(msbits DIV 2)
        ROL A                \\ A = msbits + C: SCK low, MOSI = data bit
        STA iorb%
        ORA #2
        STA iorb%            \\ SCK high, card samples MOSI
        PLA
    NEXT
    RTS
}

    \\ *** Send &FF to MMC Y times ***
    \\ Y=0=256
.MMC_16Clocks
    LDY #2
.MMC_Clocks
.MMC_SlowClocks
{
.clku1
    JSR UP_ReadByteX        ; Writes &FF
    DEY
    BNE clku1
    RTS             ; A=SR, X=1, Y=0
}


    \\ *** Send command to MMC ***
    \\ On exit A=result, Z=result=0
.MMC_DoCommand
    LDX #0

{
    LDY #7
.dcmdu1
    LDA cmdseq%,X
    JSR UP_WriteByte
    INX
    DEY
    BNE dcmdu1

    \\ wait for response bit
    \\ ie for clear bit (User Port only)
.waitresp_up
{
    LDX #(1 + msbits)
    LDY #0
.wrup
    DEY
    BEQ wrup_timeout
    LDA #(3 + msbits)
    STX iorb%
    STA iorb%
    LDA sr%
    AND #1
    BNE wrup
.wrup_timeout
    LDA #(3 + msbits)
}

    \\ This is always entered with X and A with the correct values
.UP_ReadBits7
    STX iorb%           ;\1
    STA iorb%
    STX iorb%           ;\2
    STA iorb%
    STX iorb%           ;\3
    STA iorb%
    STX iorb%           ;\4
    STA iorb%
    STX iorb%           ;\5
    STA iorb%
    STX iorb%           ;\6
    STA iorb%
    STX iorb%           ;\7
    STA iorb%
    LDA sr%

IF _DEBUG_MMC
    PHP
    PHA
    LDY #0
.dcmdu2
    LDA cmdseq%,Y
    JSR PrintHex
    INY
    CPY #7
    BNE dcmdu2
    LDA #':'
    JSR OSWRCH
    PLA
    PHA
    JSR PrintHex
    JSR OSNEWL
    PLA
    PLP
ENDIF
    RTS
}

    \\ *** Wait for data token ***
.MMC_WaitForData
{

.wlu1
    JSR UP_ReadByteX
    CMP #&FE
    BNE wlu1
    RTS
}

    \\ The read code below operates in turbo mode using shift register
    \\ mode 2. See MMC_UserPort.asm for the timing analysis.

    \\ *** Read 256 bytes to datptr ***
.MMC_Read256
    LDX #0
    BEQ MMC_ReadX

    \\ *** Read "byteslastsector" bytes
    \\ to datptr ***
.MMC_ReadBLS
    LDX byteslastsec%

.MMC_ReadX
    JSR ShiftRegMode2
    LDY #0
    LDA TubeNoTransferIf0
    BNE MMC_ReadToTube

.MMC_ReadToMemory
    JSR WaitForShiftDone
    STA (datptr%),Y
    INY
    DEX
    BNE MMC_ReadToMemory
    RTS

.MMC_ReadToTube
{
    JSR WaitForShiftDone
    STA TUBE_R3_DATA
    NOP
    NOP
    NOP
    INY
    DEX
    BNE MMC_ReadToTube
    RTS
}

    \\ **** Read 256 bytes to buffer ****
.MMC_ReadBuffer
    LDX #&FF
    STX CurrentCat
    INX

    JSR ShiftRegMode2

    LDY #0
.rdbuf2
    JSR WaitForShiftDone
    STA buf%, Y
    INY
    DEX
    BNE rdbuf2
    RTS

    \\ Read byte (User Port)
    \\ Write FF
.MMC_GetByte
.UP_ReadByteX
    LDA #(3 + msbits)   \\ Ensure CLK and MOSI both high
    STA iorb%
    JSR ShiftRegMode2
    LDA #4
.lastByte
    BIT ifr%          \\ wait for the SR interrupt flag to be set
    BEQ lastByte
    JSR ShiftRegMode0 \\ returning to mode 0 here avoids an addional byte read
    LDA sr%           \\ read the data byte, and clear the SR interrupt flag
    RTS

.WaitForShiftDone
{
    LDA #4            \\ Bit 2 of IFR is the Shift Reg Interrupt flag
    CPX #1            \\ test if the last byte
    BEQ lastByte      \\ so we can return to mode zero before reading it
.notLastByte
    BIT ifr%          \\ wait for the SR interrupt flag to be set
    BEQ notLastByte
    LDA sr%           \\ read the data byte, and clear the SR interrupt flag
    RTS
}

    \\ Reset the User VIA and select the card
    \\ SCK is taken high (SPI mode 3 idle) with no device selected, then the
    \\ card is selected, so no other device sees a spurious clock edge.
.MMC_DEVICE_RESET
    LDA #(3 + nosel)
    STA iorb%
    LDA ddrb%
    ORA #ddrmask
    STA ddrb%
    LDA #(3 + msbits)
    STA iorb%
    LDA #&1C
    STA ier%
    \\ Fall through to ShiftRegMode0

.ShiftRegMode0
    LDA acr%   \\ Set SR Mode to mode 0
    AND #&E3   \\ 11100011 = SR Mode 0
    STA acr%   \\ CB1 is now an input
    LDA ddrb%  \\ Set PB1 to being an output
    ORA #&02   \\ 00000010
    STA ddrb%
    RTS

.ShiftRegMode2
    LDA ddrb%  \\ Set PB1 to being an input
    AND #&FD   \\ 11111101
    STA ddrb%
    LDA acr%
    AND #&E3   \\ 11100011
    ORA #&08   \\ 00001000 = SR Mode 2
    STA acr%
    LDA sr%    \\ Start the first read
    RTS

    \\ Deselect the card and release the bus
    \\ An SD card keeps driving DO for a few clocks after CS goes high, so
    \\ follow the deselect with 8 clocks with no device selected.
    \\ Preserves Y. Leaves SCK high.
.MMC_DEVICE_DESELECT
{
    LDA #(3 + nosel)
    STA iorb%
    LDX #8
.loop
    LDA #(1 + nosel)
    STA iorb%
    LDA #(3 + nosel)
    STA iorb%
    DEX
    BNE loop
    RTS
}

    \\ **** Complete Write Operation *****
.MMC_EndWrite
{
    JSR MMC_16Clocks
.ewu1
    JSR UP_ReadByteX
    TAY
    AND #&1F
    CMP #&1F
    BEQ ewu1
    CMP #5
    BNE errWrite2

.ewu2
    JSR UP_ReadByteX
    CMP #&FF
    BNE ewu2
    RTS
}

    \\ **** Write 256 bytes from dataptr% ****
.MMC_Write256
{
    LDY TubeNoTransferIf0
    BNE wruT1

.wru1
    LDA (datptr%),Y
    JSR UP_WriteByte
    INY
    BNE wru1
    RTS
}

.wruT1
{
    LDY #0
.wruT2
    LDA TUBE_R3_DATA
    JSR UP_WriteByte
    INY
    BNE wruT2
    RTS
}

    \\ **** Write 256 bytes from buffer ****
.MMC_WriteBuffer
{
    LDY #0
.wbu1
    LDA buf%,Y
    JSR UP_WriteByte
    INY
    BNE wbu1
    RTS
}
