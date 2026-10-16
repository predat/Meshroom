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
