#Requires AutoHotkey v2.0
#SingleInstance Force

; ================================================================
;  모니터 백라이트 얼룩(누런 끼) 완화용 그라데이션 오버레이
;  대상: Alienware AW3418DW (우측 하단 얼룩, 실측 사진 기준 보정)
;
;  동작 원리
;  - 화면에서 경계선(아래 gradPoints) 위쪽은 그대로 두고(보정 없음)
;  - 경계선 아래쪽(얼룩이 있는 우하단 방향)을 향해 부드러운
;    그라데이션으로 점점 어둡게 덮어서 밝기/색감을 맞춤
;  - GDI 레이어드 윈도우(픽셀별 알파)로 렌더링 → 계단 없는 매끈한 그라데이션
;  - 클릭/키보드 입력은 모두 아래 프로그램으로 그대로 통과됨 (클릭스루)
;
;  단축키 / 트레이 메뉴
;  - Ctrl+Alt+O   : 오버레이 켜기/끄기
;  - 트레이 아이콘 우클릭 → Exit : 완전 종료
;  - 트레이 아이콘 우클릭 → "시작프로그램 등록" : Windows 부팅 시 자동 실행 on/off
; ================================================================


; ---------------------------------------------------------------
; ① 필요할 때 이 값들만 조절하면 됩니다
; ---------------------------------------------------------------
maxAlpha     := 70      ; 가장 어둡게 덮을 진하기 (0~255, 클수록 진함)
minAlpha     := 7       ; 얼룩(무보정 구역)에도 아주 살짝 깔아주는 최소 진하기
                        ;   0으로 두면 얼룩 부분은 완전 무보정
falloffDepth := 0.80    ; 경계선에서 위로 화면 세로 비율 이만큼 올라가면 최대 진하기 도달
                        ;   (값이 클수록 그라데이션이 더 넓고 완만하게 퍼짐)
yellowFix    := 8       ; 누런끼 상쇄 강도 (0~40 권장, 0이면 끔)
                        ;   얼룩 구역에만 푸른빛을 섞어 노란기를 눌러줍니다.
                        ;   빨강·초록만 더 깎는 방식이라 값이 클수록 그 부분이 살짝 더 어두워지고,
                        ;   검은 화면에서는 아주 옅은 푸른기가 돌 수 있습니다.
toggleKey    := "^!o"   ; 켜고 끄는 단축키 (기본: Ctrl+Alt+O)
gradScale    := 5       ; 그라데이션 연산 해상도 축소 배율
                        ;   작을수록 촘촘하고 매끄럽지만 시작할 때 계산이 오래 걸림
                        ;   (10≈0.3초 / 5≈1.5초 / 4≈2.5초)
dither       := true    ; 알파가 정수라 생기는 계단(밴딩)을 미세 노이즈로 흩어줌

; ── 무보정 경계선 ──────────────────────────────────────────────
; 화면 비율 좌표 (x: 왼쪽 0.0 ~ 오른쪽 1.0 / y: 위 0.0 ~ 아래 1.0)
; 이 선 "아래"(백라이트 나간 누런 부분)는 무보정,
; 이 선 "위"로 갈수록 점점 진하게 덮어 전체 밝기를 맞춥니다.
;
; y 값이 1.0을 넘으면 화면 아래쪽 바깥 = 그 세로줄은 전부 보정 대상이 됩니다.
; 얼룩이 오른쪽에만 있으므로 왼쪽은 1.0을 넘겨 무보정 구역을 없앴습니다.
; 왼쪽 끝은 패널 자체가 이미 살짝 어두워서(비네팅) 보정을 조금 덜 넣습니다.
gradPoints := [
    {x: 0.00, y: 0.88},
    {x: 0.15, y: 0.94},
    {x: 0.35, y: 0.96},
    {x: 0.55, y: 0.89},
    {x: 0.75, y: 0.79},
    {x: 1.00, y: 0.72}
]


; ---------------------------------------------------------------
; ② 내부 동작 (평소엔 건드릴 필요 없음)
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

; 경계선(gradPoints)을 구간별 매끄러운 보간으로 잇는 함수: u(가로비율) → v(경계선 세로비율)
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

; 32bpp top-down DIB 섹션 생성 (알파 채널 포함)
CreateDIB32(w, h) {
    bi := Buffer(40, 0)
    NumPut("Int", 40, bi, 0)      ; biSize
    NumPut("Int", w, bi, 4)       ; biWidth
    NumPut("Int", -h, bi, 8)      ; biHeight (음수 = top-down)
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

; 저해상도로 그라데이션 알파를 계산한 뒤, 화면 전체 크기로 확대(StretchBlt)
BuildGradientBitmap() {
    global screenW, screenH, maxAlpha, minAlpha, falloffDepth, yellowFix, gradScale, dither

    gw := Max(Round(screenW / gradScale), 40)
    gh := Max(Round(screenH / gradScale), 30)

    low := CreateDIB32(gw, gh)

    ; 4x4 Bayer 디더 행렬. 알파를 정수로 반올림할 때 생기는 계단(밴딩)을
    ; 픽셀마다 -0.5 ~ +0.5 범위로 미세하게 흔들어 눈에 안 띄게 흩어준다.
    bayer := [ 0, 8, 2,10
             ,12, 4,14, 6
             , 3,11, 1, 9
             ,15, 7,13, 5]

    loop gh {
        y := A_Index - 1
        v := (gh = 1) ? 0 : y / (gh - 1)
        rowOffset := y * gw * 4
        bRow := Mod(y, 4) * 4          ; 이 행의 디더 행렬 시작 위치

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
            if (alphaF < minAlpha)   ; 얼룩 구역도 최소한 이만큼은 깔아준다
                alphaF := minAlpha

            ; ── 누런끼 상쇄 ─────────────────────────────────────
            ; 보정이 약한 곳(=얼룩)일수록 강하게, 이미 진한 곳은 0.
            ; 빨강·초록만 추가로 깎고 파랑은 그대로 두어 노란기를 중화한다.
            ;   결과: R,G는 (alpha + fix)만큼, B는 alpha만큼 감소 → 파랑이 fix만큼 상대적으로 올라감
            fixF := 0.0
            if (yellowFix > 0 && maxAlpha > 0) {
                fixF := yellowFix * (1 - (alphaF / maxAlpha))
                if (fixF < 0)
                    fixF := 0.0
            }

            ; 정수로 떨굴 때 디더 오프셋을 더해 밴딩 완화
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
            if (fix > aTotal)        ; 미리 곱해진 색은 알파를 넘을 수 없음
                fix := aTotal

            off := rowOffset + (x * 4)
            NumPut("UChar", fix, low.bits, off)         ; B (미리 곱해진 값)
            NumPut("UChar", 0, low.bits, off + 1)       ; G
            NumPut("UChar", 0, low.bits, off + 2)       ; R
            NumPut("UChar", aTotal, low.bits, off + 3)  ; A
        }
    }

    full := CreateDIB32(screenW, screenH)
    ; StretchBlt(HALFTONE)는 32bpp 알파 채널을 보존하지 못해 알파가 깨지는 문제가 있어
    ; 알파를 인식하는 AlphaBlend로 확대(겸 합성)한다. dest가 전부 투명(0)에서 시작하므로
    ; 결과적으로 source를 그대로 부드럽게 확대한 것과 동일해진다.
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
        ToolTip("모니터 보정 OFF")
    } else {
        if (overlayGui = "")
            BuildOverlay()
        else
            overlayGui.Show("NA")
        overlayOn := true
        ToolTip("모니터 보정 ON")
    }
    SetTimer(() => ToolTip(), -1000)
}


; ---------------------------------------------------------------
; ③ 시작프로그램 등록 (트레이 메뉴에서 토글)
; ---------------------------------------------------------------
startupLink := A_Startup "\MonitorBacklightBalance.lnk"

ToggleStartup(*) {
    global startupLink
    if FileExist(startupLink) {
        FileDelete(startupLink)
        ToolTip("시작프로그램 등록 해제됨")
    } else {
        FileCreateShortcut(A_ScriptFullPath, startupLink, A_ScriptDir, "", "모니터 백라이트 보정")
        ToolTip("시작프로그램에 등록됨")
    }
    SetTimer(() => ToolTip(), -1200)
    UpdateStartupMenuCheck()
}

UpdateStartupMenuCheck() {
    global startupLink
    if FileExist(startupLink)
        A_TrayMenu.Check("시작프로그램 등록")
    else
        A_TrayMenu.Uncheck("시작프로그램 등록")
}

A_TrayMenu.Add()
A_TrayMenu.Add("시작프로그램 등록", ToggleStartup)
UpdateStartupMenuCheck()


; ---------------------------------------------------------------
; ④ 시작 시 자동으로 켜기
; ---------------------------------------------------------------
BuildOverlay()
overlayOn := true

Hotkey(toggleKey, ToggleOverlay)
