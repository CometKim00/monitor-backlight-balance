#Requires AutoHotkey v2.0
#SingleInstance Force

; ================================================================
;  Monitor Backlight Balance
;  Evens out LCD backlight bleed / clouding / uniformity defects.
;
;  Defaults are tuned for one Alienware AW3418DW with a dim, yellowed
;  patch in the lower-right. YOU WILL NEED TO RETUNE THEM.
;  See docs/CALIBRATION.md.
;
;  How it works
;  - A boundary line (gradPoints) marks where the panel defect is.
;  - Below that line the screen is left alone; above it, a smooth
;    gradient dims the healthy panel down to match the defect.
;  - Rendered as a GDI layered window with per-pixel alpha, so the
;    gradient is continuous rather than stepped.
;  - Click-through: all mouse and keyboard input passes underneath.
;
;  Hotkey / tray menu
;  - Ctrl+Alt+O                     : toggle the overlay
;  - Tray icon -> Exit              : quit
;  - Tray icon -> Run at startup    : toggle launching on Windows boot
; ================================================================


; ---------------------------------------------------------------
; (1) TUNING - these are the only values you should need to touch
; ---------------------------------------------------------------
maxAlpha     := 70      ; Strongest dimming, 0-255. Higher = darker.
minAlpha     := 7       ; Floor applied everywhere, including inside the
                        ;   defect. Set to 0 to leave the defect untouched.
falloffDepth := 0.80    ; How far above the boundary the gradient ramps
                        ;   before reaching maxAlpha, in screen heights.
                        ;   Higher = wider and gentler.
yellowFix    := 8       ; Yellow-cast compensation, 0-40. 0 disables it.
                        ;   Adds a blue tint over the defect only. Works by
                        ;   cutting red and green further, so higher values
                        ;   dim that area slightly more and leave a faint
                        ;   blue cast on black content.
toggleKey    := "^!o"   ; Show/hide hotkey. Default: Ctrl+Alt+O
gradScale    := 5       ; Compute-resolution divisor. Lower = finer gradient
                        ;   but slower startup.
                        ;   (10 = ~0.3s, 5 = ~1.5s, 4 = ~2.5s)
dither       := true    ; Scatter the banding caused by integer alpha.

; -- Boundary line ----------------------------------------------
; Normalized screen coordinates (x: 0.0 left -> 1.0 right,
;                                y: 0.0 top  -> 1.0 bottom)
; BELOW this line = the defective area, left uncorrected.
; ABOVE this line = progressively dimmed to match it.
;
; A y value above 1.0 puts the boundary off the bottom of the screen,
; meaning that whole column gets corrected. Use this where the defect
; doesn't reach - here it only affects the right side, so the left is
; pushed past 1.0... except at the very edge, where the panel already
; vignettes and therefore needs less correction, not more.
gradPoints := [
    {x: 0.00, y: 0.88},
    {x: 0.15, y: 0.94},
    {x: 0.35, y: 0.96},
    {x: 0.55, y: 0.89},
    {x: 0.75, y: 0.79},
    {x: 1.00, y: 0.72}
]


; ---------------------------------------------------------------
; (2) INTERNALS - no need to edit below here
; ---------------------------------------------------------------
screenW := A_ScreenWidth
screenH := A_ScreenHeight

overlayGui := ""
overlayOn := false

Smoothstep(t) {
    if (t <= 0)
        return 0
    if (t >= 1)
        return 1
    return t * t * (3 - 2 * t)
}

; Interpolate the boundary polyline: u (x fraction) -> v (y fraction)
BoundaryV(u) {
    global gradPoints
    n := gradPoints.Length
    if (u <= gradPoints[1].x)
        return gradPoints[1].y
    if (u >= gradPoints[n].x)
        return gradPoints[n].y
    loop n - 1 {
        p1 := gradPoints[A_Index]
        p2 := gradPoints[A_Index + 1]
        if (u >= p1.x && u <= p2.x) {
            t := (p2.x = p1.x) ? 0 : (u - p1.x) / (p2.x - p1.x)
            return p1.y + (p2.y - p1.y) * Smoothstep(t)
        }
    }
    return gradPoints[n].y
}

; Create a 32bpp top-down DIB section (with alpha channel)
CreateDIB32(w, h) {
    bi := Buffer(40, 0)
    NumPut("Int", 40, bi, 0)      ; biSize
    NumPut("Int", w, bi, 4)       ; biWidth
    NumPut("Int", -h, bi, 8)      ; biHeight (negative = top-down)
    NumPut("Short", 1, bi, 12)    ; biPlanes
    NumPut("Short", 32, bi, 14)   ; biBitCount
    NumPut("Int", 0, bi, 16)      ; BI_RGB

    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    ppvBits := 0
    hBitmap := DllCall("gdi32\CreateDIBSection"
        , "Ptr", hdcScreen, "Ptr", bi, "UInt", 0, "Ptr*", &ppvBits, "Ptr", 0, "UInt", 0, "Ptr")
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)

    hdcMem := DllCall("gdi32\CreateCompatibleDC", "Ptr", 0, "Ptr")
    hOld := DllCall("gdi32\SelectObject", "Ptr", hdcMem, "Ptr", hBitmap, "Ptr")

    return { hdc: hdcMem, hBitmap: hBitmap, bits: ppvBits, hOld: hOld, w: w, h: h }
}

DestroyDIB(dib) {
    DllCall("gdi32\SelectObject", "Ptr", dib.hdc, "Ptr", dib.hOld)
    DllCall("gdi32\DeleteObject", "Ptr", dib.hBitmap)
    DllCall("gdi32\DeleteDC", "Ptr", dib.hdc)
}

; Compute the alpha map at reduced resolution, then scale it up.
BuildGradientBitmap() {
    global screenW, screenH, maxAlpha, minAlpha, falloffDepth, yellowFix, gradScale, dither

    gw := Max(Round(screenW / gradScale), 40)
    gh := Max(Round(screenH / gradScale), 30)

    low := CreateDIB32(gw, gh)

    ; 4x4 Bayer matrix. Alpha is an 8-bit integer, so a 7->70 ramp across
    ; 1440px puts each step ~23px apart - clearly visible as bands. Nudging
    ; each pixel by -0.5..+0.5 before rounding scatters those transitions.
    bayer := [ 0, 8, 2,10
             ,12, 4,14, 6
             , 3,11, 1, 9
             ,15, 7,13, 5]

    loop gh {
        y := A_Index - 1
        v := (gh = 1) ? 0 : y / (gh - 1)
        rowOffset := y * gw * 4
        bRow := Mod(y, 4) * 4          ; start of this row in the dither matrix

        loop gw {
            x := A_Index - 1
            u := (gw = 1) ? 0 : x / (gw - 1)

            bV := BoundaryV(u)
            alphaF := 0.0
            if (v < bV) {
                d := (falloffDepth <= 0) ? 1 : (bV - v) / falloffDepth
                if (d > 1)
                    d := 1
                alphaF := maxAlpha * Smoothstep(d)
            }
            if (alphaF < minAlpha)   ; apply the floor inside the defect too
                alphaF := minAlpha

            ; -- Yellow-cast compensation ------------------------------
            ; Strongest where correction is weakest (the defect), zero where
            ; the overlay is already at full strength - so overall color
            ; balance is untouched.
            ;
            ; Writing premultiplied blue = fix with total alpha = alpha + fix
            ; composites to:  R,G reduced by (alpha + fix)
            ;                 B   reduced by  alpha
            ; i.e. a net blue shift of `fix`, cancelling the yellow.
            fixF := 0.0
            if (yellowFix > 0 && maxAlpha > 0) {
                fixF := yellowFix * (1 - (alphaF / maxAlpha))
                if (fixF < 0)
                    fixF := 0.0
            }

            dOff := dither ? (bayer[bRow + Mod(x, 4) + 1] / 16) - 0.5 : 0

            alpha := Floor(alphaF + dOff + 0.5)
            fix   := Floor(fixF   + dOff + 0.5)
            if (alpha < 0)
                alpha := 0
            if (fix < 0)
                fix := 0

            aTotal := alpha + fix
            if (aTotal > 255)
                aTotal := 255
            if (fix > aTotal)        ; premultiplied color can't exceed alpha
                fix := aTotal

            off := rowOffset + (x * 4)
            NumPut("UChar", fix, low.bits, off)         ; B (premultiplied)
            NumPut("UChar", 0, low.bits, off + 1)       ; G
            NumPut("UChar", 0, low.bits, off + 2)       ; R
            NumPut("UChar", aTotal, low.bits, off + 3)  ; A
        }
    }

    full := CreateDIB32(screenW, screenH)
    ; StretchBlt does not preserve the 32bpp alpha channel, which corrupts the
    ; gradient. AlphaBlend is alpha-aware; since the destination starts fully
    ; transparent, blending onto it is equivalent to a smooth upscale.
    blendFlag := (1 << 24) | (255 << 16) | (0 << 8) | 0  ; AC_SRC_ALPHA<<24 | SourceConstantAlpha<<16
    DllCall("msimg32\AlphaBlend"
        , "Ptr", full.hdc, "Int", 0, "Int", 0, "Int", screenW, "Int", screenH
        , "Ptr", low.hdc, "Int", 0, "Int", 0, "Int", gw, "Int", gh
        , "UInt", blendFlag)

    DestroyDIB(low)
    return full
}

BuildOverlay() {
    global overlayGui, screenW, screenH

    full := BuildGradientBitmap()

    g := Gui("+E0x80020 +AlwaysOnTop -Caption +ToolWindow")  ; WS_EX_LAYERED | WS_EX_TRANSPARENT
    g.Show("x0 y0 w" screenW " h" screenH " NA Hide")
    hwnd := g.Hwnd

    ptSrc := Buffer(8, 0)
    sizeWnd := Buffer(8, 0)
    NumPut("Int", screenW, sizeWnd, 0)
    NumPut("Int", screenH, sizeWnd, 4)
    blend := Buffer(4, 0)
    NumPut("UChar", 0, blend, 0)    ; AC_SRC_OVER
    NumPut("UChar", 0, blend, 1)    ; reserved
    NumPut("UChar", 255, blend, 2)  ; SourceConstantAlpha
    NumPut("UChar", 1, blend, 3)    ; AC_SRC_ALPHA

    DllCall("UpdateLayeredWindow"
        , "Ptr", hwnd, "Ptr", 0, "Ptr", 0, "Ptr", sizeWnd
        , "Ptr", full.hdc, "Ptr", ptSrc, "UInt", 0, "Ptr", blend, "UInt", 2) ; ULW_ALPHA

    DestroyDIB(full)

    g.Show("NA")
    overlayGui := g
}

DestroyOverlay() {
    global overlayGui
    if (overlayGui != "") {
        overlayGui.Destroy()
        overlayGui := ""
    }
}

ToggleOverlay(*) {
    global overlayOn, overlayGui
    if overlayOn {
        overlayGui.Hide()
        overlayOn := false
        ToolTip("Backlight Balance: OFF")
    } else {
        if (overlayGui = "")
            BuildOverlay()
        else
            overlayGui.Show("NA")
        overlayOn := true
        ToolTip("Backlight Balance: ON")
    }
    SetTimer(() => ToolTip(), -1000)
}


; ---------------------------------------------------------------
; (3) Startup registration (toggled from the tray menu)
; ---------------------------------------------------------------
startupLink := A_Startup "\MonitorBacklightBalance.lnk"
startupMenuText := "Run at startup"

ToggleStartup(*) {
    global startupLink
    if FileExist(startupLink) {
        FileDelete(startupLink)
        ToolTip("Removed from startup")
    } else {
        FileCreateShortcut(A_ScriptFullPath, startupLink, A_ScriptDir, "", "Monitor Backlight Balance")
        ToolTip("Added to startup")
    }
    SetTimer(() => ToolTip(), -1200)
    UpdateStartupMenuCheck()
}

UpdateStartupMenuCheck() {
    global startupLink, startupMenuText
    if FileExist(startupLink)
        A_TrayMenu.Check(startupMenuText)
    else
        A_TrayMenu.Uncheck(startupMenuText)
}

A_TrayMenu.Add()
A_TrayMenu.Add(startupMenuText, ToggleStartup)
UpdateStartupMenuCheck()


; ---------------------------------------------------------------
; (4) Start with the overlay on
; ---------------------------------------------------------------
BuildOverlay()
overlayOn := true

Hotkey(toggleKey, ToggleOverlay)
