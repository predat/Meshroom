pragma Singleton
import QtQuick
import QtQuick.Controls

/**
 * Singleton that gathers useful colors, shades and system palettes.
 */

QtObject {
    property SystemPalette sysPalette: SystemPalette {}
    property SystemPalette disabledSysPalette: SystemPalette { colorGroup: SystemPalette.Disabled }

    readonly property color green: "#4CAF50"
    readonly property color orange: "#FF9800"
    readonly property color yellow: "#FFEB3B"
    readonly property color red: "#F44336"
    readonly property color crimson: "#DC143C"
    readonly property color firebrick: "#B22222"
    readonly property color blue: "#03A9F4"
    readonly property color cyan: "#00BCD4"
    readonly property color pink: "#E91E63"
    readonly property color lime: "#CDDC39"
    readonly property color grey: "#555555"
    readonly property color lightgrey: "#999999"
    readonly property color warning: "#FF9800"
    readonly property color darkpurple: "#5c4885"

    readonly property var statusColors: {
        "NONE": "transparent",
        "SUBMITTED": cyan,
        "RUNNING": orange,
        "ERROR": red,
        "SUCCESS": green,
        "STOPPED": pink,
        "INPUT": "transparent"
    }

    readonly property var ghostColors: {
        "SUBMITTED": Qt.darker(cyan, 1.5),
        "RUNNING": Qt.darker(orange, 1.5),
        "STOPPED": Qt.darker(pink, 1.5)
    }

    readonly property var statusColorsExternOverrides: {
        "SUBMITTED": "#2196F3"
    }

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

    function dataTypeColor(dataType) {
        const color = dataTypeColors[dataType] || dataTypeGeneric
        // Tokens are tuned for dark backgrounds: darken them to keep contrast on a light palette
        return sysPalette.window.hslLightness > 0.5 ? Qt.darker(color, 1.35) : color
    }

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

    // Graph Editor node tokens: dark values, with a light variant (text contrast >= 4.5:1 on the node background)
    readonly property bool lightPalette: sysPalette.window.hslLightness > 0.5
    readonly property color nodeBackground: lightPalette ? "#F6F7F9" : "#1D2027"
    readonly property color nodeBorder: lightPalette ? "#CDD2DA" : "#2D323C"
    readonly property color nodeText: lightPalette ? "#1D2027" : "#EEF0F3"
    readonly property color nodeTextSecondary: lightPalette ? "#5B6370" : "#9AA1AD"
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

    // Icon tile of a node, by node type category (Material icon name + tint); "" is the fallback
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
        "Export": { "icon": "ios_share", "color": "#9AA1AD" },
        "Utils": { "icon": "build", "color": "#9AA1AD" },
        "": { "icon": "category", "color": "#9AA1AD" }
    }

    function categoryStyle(category) {
        return categoryStyles[category] || categoryStyles[""]
    }

    // Token colors are tuned for dark backgrounds: darken them to keep contrast on a light palette
    function tokenColor(color) {
        return lightPalette ? Qt.darker(color, 1.8) : color
    }

    readonly property var durationColorScale: [
        {"time": 0, "color": grey},
        {"time": 5, "color": green},
        {"time": 20, "color": yellow},
        {"time": 90, "color": red}
    ]

    function getChunkColor(chunk, overrides) {
        if (chunk === undefined || chunk == null)
            return "transparent"
        if (overrides && chunk.statusName in overrides) {
            return overrides[chunk.statusName]
        } else if (chunk.execModeName === "EXTERN" && chunk.statusName in statusColorsExternOverrides) {
            return statusColorsExternOverrides[chunk.statusName]
        } else if (chunk.nodeName !== chunk.statusNodeName && chunk.statusName in ghostColors) {
            return ghostColors[chunk.statusName]
        } else if (chunk.statusName in statusColors) {
            return statusColors[chunk.statusName]
        }
        console.warn("Unknown status : " + chunk.status)
        return "magenta"
    }

    // Chunk color from the Graph Editor node tokens
    function getNodeChunkColor(chunk) {
        if (chunk === undefined || chunk == null)
            return "transparent"
        if (chunk.statusName === "NONE")
            return nodeBorder
        if (chunk.execModeName === "EXTERN" && (chunk.statusName === "SUBMITTED" || chunk.statusName === "RUNNING"))
            return nodeStatusFarm
        const color = nodeStatusColors[chunk.statusName] || nodeStatusColors["NONE"]
        // Status shared with another node computing the same data
        if (chunk.nodeName !== chunk.statusNodeName && chunk.statusName in ghostColors)
            return Qt.darker(color, 1.5)
        return color
    }

    function getNodeColor(node, overrides) {
        if (node === undefined)
            return "transparent"
        if (overrides && node.globalStatus in overrides) {
            return overrides[node.globalStatus]
        } else if (node.globalExecMode === "EXTERN" && node.globalStatus in statusColorsExternOverrides) {
            return statusColorsExternOverrides[node.globalStatus]
        } else if (node.name !== node.nodeStatusNodeName && node.globalStatus in ghostColors) {
            return ghostColors[node.globalStatus]
        } else if (node.globalStatus in statusColors) {
            return statusColors[node.globalStatus]
        }
        console.warn("Unknown status : " + node.globalStatus)
        return "magenta"
    }

    function toRgb(color) {
        return [
            parseInt(color.toString().substr(1, 2), 16) / 255, 
            parseInt(color.toString().substr(3, 2), 16) / 255, 
            parseInt(color.toString().substr(5, 2), 16) / 255
        ]
    }

    function interpolate(c1, c2, u) {
        let rgb1 = toRgb(c1)
        let rgb2 = toRgb(c2)
        return Qt.rgba(
            rgb1[0] * (1 - u) + rgb2[0] * u,
            rgb1[1] * (1 - u) + rgb2[1] * u,
            rgb1[2] * (1 - u) + rgb2[2] * u
        )
    }

    function durationColor(t) {
        if (t < durationColorScale[0].time) {
            return durationColorScale[0].color
        }
        if (t > durationColorScale[durationColorScale.length-1].time) {
            return durationColorScale[durationColorScale.length-1].color
        }
        for (let idx = 1; idx < durationColorScale.length; idx++) {
            if (t < durationColorScale[idx].time) {
                let u = (t - durationColorScale[idx - 1].time) / (durationColorScale[idx].time - durationColorScale[idx - 1].time)
                return interpolate(durationColorScale[idx - 1].color, durationColorScale[idx].color, u)
            }
        }
    }
}
