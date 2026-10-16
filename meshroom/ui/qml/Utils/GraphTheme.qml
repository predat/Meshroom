pragma Singleton
import QtQuick

/**
 * Graph Editor design tokens: node, status, data type and category colors, and the embedded fonts.
 * Dark values, with a light variant derived from the system palette.
 */

QtObject {
    property SystemPalette sysPalette: SystemPalette {}

    // Colors of the attributes' displayable data types (Attribute.dataType)
    readonly property color dataTypeGeneric: "#9AA1AD"
    readonly property var dataTypeColors: {
        "sfmData": "#B48CF2",
        "features": "#E5A54B",
        "folder": "#E5A54B",
        "image": "#5FB3F5",
        "imagePairs": "#5FB3F5",
        "matches": "#6CC785",
        "tracks": "#6CC785",
        "mesh": "#6CC785"
    }

    // Color of a data type drawn on `surface` (the graph by default). The tokens are tuned for dark surfaces: on a light
    // one, same hue at HSL lightness 0.38 and saturated, >= 3:1 on the light graph
    function dataTypeColor(dataType, surface) {
        const color = Qt.color(dataTypeColors[dataType] || dataTypeGeneric)
        if (!isLight(surface === undefined ? sysPalette.window : surface))
            return color
        return Qt.hsla(color.hslHue, Math.min(color.hslSaturation * 1.2, 1), 0.38, 1)
    }
    // Opacity of the edges whose data is not produced yet: raised on a light graph to keep >= 2:1
    readonly property real edgeNotProducedOpacity: lightPalette ? 0.62 : 0.55

    // Graph Editor fonts (meshroom/ui/fonts, OFL 1.1), with a fallback on the system fonts if one of them fails to load
    property FontLoader plexRegular: FontLoader { source: "../../fonts/IBMPlexSans-Regular.ttf" }
    property FontLoader plexMedium: FontLoader { source: "../../fonts/IBMPlexSans-Medium.ttf" }
    property FontLoader plexSemiBold: FontLoader { source: "../../fonts/IBMPlexSans-SemiBold.ttf" }
    property FontLoader plexCondensedSemiBold: FontLoader { source: "../../fonts/IBMPlexSansCondensed-SemiBold.ttf" }
    property FontLoader monoRegular: FontLoader { source: "../../fonts/JetBrainsMono-Regular.ttf" }
    readonly property bool sansLoaded: [plexRegular, plexMedium, plexSemiBold].every(loader => loader.status === FontLoader.Ready)
    readonly property bool headerLoaded: plexCondensedSemiBold.status === FontLoader.Ready
    readonly property bool monoLoaded: monoRegular.status === FontLoader.Ready
    readonly property bool fontsLoaded: sansLoaded && headerLoaded && monoLoaded
    readonly property string fontFamily: sansLoaded ? plexRegular.name : Qt.application.font.family
    // Node header labels and Backdrop titles only
    readonly property string headerFamily: headerLoaded ? plexCondensedSemiBold.name : fontFamily
    readonly property string monoFamily: monoLoaded ? monoRegular.name : "monospace"

    // Local files: the loaders are already Ready or in Error once the singleton is created
    Component.onCompleted: {
        for (const loader of [plexRegular, plexMedium, plexSemiBold, plexCondensedSemiBold, monoRegular]) {
            if (loader.status === FontLoader.Error)
                console.warn("Graph Editor font could not be loaded, using its fallback: " + loader.source)
        }
    }

    // Graph Editor node tokens, derived from the application palette without any hue: the graph is drawn on
    // palette.window, the nodes are always lighter than it, the text contrast is >= 4.5:1
    readonly property bool lightPalette: isLight(sysPalette.window)
    readonly property color graphBackground: gray(sysPalette.window)
    // The rendering of the nodes before the Graph Editor redesign (Qt.lighter(base, 1.4) at 0.85 on the graph), gray and
    // opaque; in a dark palette it is darker than the graph: raised to 1.25:1 above it
    readonly property color nodeBackground: {
        const color = gray(composite(Qt.lighter(sysPalette.base, 1.4), sysPalette.window, 0.85))
        if (lightPalette)
            return color
        return grayOfLuminance(Math.max(luminance(color), 1.25 * (luminance(graphBackground) + 0.05) - 0.05))
    }
    readonly property color nodeHeader: Qt.darker(nodeBackground, 1.15)
    readonly property color nodeBorder: borderOn(nodeBackground)
    readonly property color nodeText: gray(sysPalette.text)
    readonly property color nodeTextSecondary: secondaryText(nodeText, [nodeBackground, nodeHeader])
    // Secondary text on the panels (palette.window), e.g. the Node Editor
    readonly property color panelTextSecondary: secondaryText(nodeText, [sysPalette.window])
    readonly property color nodeSelection: tokenColor("#4C9AFF")
    readonly property color nodeInvalid: tokenColor("#F0B44C")
    readonly property color nodeModified: "#F0B44C"
    readonly property var nodeStatusColors: {
        "NONE": tokenColor("#8B949E"),
        "SUBMITTED": tokenColor("#8B949E"),
        "RUNNING": tokenColor("#4C9AFF"),
        "ERROR": tokenColor("#F85149"),
        "SUCCESS": tokenColor("#3FB950"),
        "STOPPED": tokenColor("#F0B44C"),
        "KILLED": tokenColor("#F85149"),
        "INPUT": "transparent"
    }
    readonly property color nodeStatusFarm: tokenColor("#A371F7")
    // Edges cutting (knife): the error status color
    readonly property color edgeCut: nodeStatusColors["ERROR"]

    // Icon tile of a node, by node type category (Material icon name + hue); "" is the neutral fallback
    readonly property var categoryStyles: {
        "Sparse Reconstruction": { "icon": "scatter_plot", "color": "#B48CF2" },
        "Dense Reconstruction": { "icon": "grain", "color": "#6CC785" },
        "Mesh Generation": { "icon": "view_in_ar", "color": "#6CC785" },
        "Mesh Post-Processing": { "icon": "view_in_ar", "color": "#6CC785" },
        "Panorama HDR": { "icon": "panorama", "color": "#5FB3F5" },
        "Photometric Stereo": { "icon": "light_mode", "color": "#E5A54B" },
        "Image Intrinsics": { "icon": "image", "color": "#5FB3F5" },
        "SDR to HDR": { "icon": "image", "color": "#5FB3F5" },
        "Segmentation": { "icon": "content_cut", "color": "#E5A54B" },
        "Matting": { "icon": "content_cut", "color": "#E5A54B" },
        "Geolocation": { "icon": "place", "color": "#5FB3F5" },
        "Video Utils": { "icon": "movie", "color": "#5FB3F5" },
        "Export": { "icon": "ios_share", "color": "#E87FAF" },
        "Utils": { "icon": "build", "color": "#9AA1AD" },
        "": { "icon": "category", "color": "#9AA1AD" }
    }

    function categoryStyle(category) {
        return categoryStyles[category] || categoryStyles[""]
    }

    // Relative luminance (WCAG) of a color
    function luminance(color) {
        const channel = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    // Contrast ratio (WCAG) of two colors, from 1 to 21
    function contrast(a, b) {
        const la = luminance(a)
        const lb = luminance(b)
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
    }

    function isLight(surface) {
        return Qt.color(surface).hslLightness > 0.5
    }

    // Gray of a relative luminance
    function grayOfLuminance(l) {
        const v = l <= 0.0031308 ? l * 12.92 : 1.055 * Math.pow(l, 1 / 2.4) - 0.055
        return Qt.rgba(v, v, v, 1)
    }

    // Gray of the same relative luminance as a color
    function gray(color) {
        return grayOfLuminance(luminance(color))
    }

    // Gray darker than a color by a contrast ratio
    function darkerByContrast(color, ratio) {
        return grayOfLuminance(Math.max((luminance(color) + 0.05) / ratio - 0.05, 0))
    }

    // Opaque color of `color` drawn at `opacity` on `background`
    function composite(color, background, opacity) {
        return Qt.rgba(color.r * opacity + background.r * (1 - opacity), color.g * opacity + background.g * (1 - opacity),
                       color.b * opacity + background.b * (1 - opacity), 1)
    }

    // Border of a node body: lighter than the body in a dark palette, darker in a light one
    function borderOn(body) {
        return lightPalette ? Qt.darker(body, 1.15) : Qt.lighter(body, 1.35)
    }

    // Black or white, whichever has the best contrast on all the surfaces: >= 4.58:1 on any color
    function textOn(surfaces) {
        const white = Qt.rgba(1, 1, 1, 1)
        const black = Qt.rgba(0, 0, 0, 1)
        const minContrast = text => Math.min(...surfaces.map(surface => contrast(text, surface)))
        return minContrast(white) >= minContrast(black) ? white : black
    }

    // Secondary text: `text` mixed toward the first surface, as far as its contrast on all the surfaces stays >= 4.5:1
    function secondaryText(text, surfaces) {
        let low = 0
        let high = 1
        for (let i = 0; i < 10; ++i) {
            const mix = (low + high) / 2
            const color = composite(text, surfaces[0], 1 - mix)
            if (Math.min(...surfaces.map(surface => contrast(color, surface))) >= 4.5)
                low = mix
            else
                high = mix
        }
        return composite(text, surfaces[0], 1 - low)
    }

    // Token colors are tuned for dark backgrounds: darken them to keep contrast on a light palette
    function tokenColor(color) {
        return lightPalette ? Qt.darker(color, 1.8) : color
    }

    // Chunk color from the Graph Editor node tokens
    function getNodeChunkColor(chunk) {
        if (chunk === undefined || chunk == null)
            return "transparent"
        // Neutral placeholder, visible on the node background
        if (chunk.statusName === "NONE")
            return Qt.alpha(nodeTextSecondary, 0.35)
        if (chunk.execModeName === "EXTERN" && (chunk.statusName === "SUBMITTED" || chunk.statusName === "RUNNING"))
            return nodeStatusFarm
        const color = nodeStatusColors[chunk.statusName] || nodeStatusColors["NONE"]
        // Status shared with another node computing the same data
        if (chunk.nodeName !== chunk.statusNodeName && chunk.statusName in Colors.ghostColors)
            return Qt.darker(color, 1.5)
        return color
    }
}
