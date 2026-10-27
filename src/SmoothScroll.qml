import QtQuick

// Wheel scrolling that glides instead of jumping a few lines at a time: a
// mouse wheel notch eases the view along, a touchpad moves it pixel for
// pixel. Put one inside a ListView or Flickable and point flick at it.
WheelHandler {
    id: handler
    property Flickable flick
    // How far one wheel notch goes.
    property real step: 110
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

    function clamp(y) {
        const top = flick.originY - flick.topMargin
        const bottom = Math.max(top, flick.originY + flick.contentHeight + flick.bottomMargin - flick.height)
        return Math.max(top, Math.min(bottom, y))
    }

    onWheel: event => {
        if (event.pixelDelta.y !== 0) {
            glide.stop()
            flick.contentY = clamp(flick.contentY - event.pixelDelta.y)
        } else if (event.angleDelta.y !== 0) {
            const from = glide.running ? glide.to : flick.contentY
            glide.to = clamp(from - event.angleDelta.y / 120 * step)
            glide.from = flick.contentY
            glide.restart()
        }
        event.accepted = true
    }

    property NumberAnimation glide: NumberAnimation {
        target: handler.flick
        property: "contentY"
        duration: 180
        easing.type: Easing.OutCubic
    }
}
