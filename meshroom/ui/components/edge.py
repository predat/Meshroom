from PySide6.QtCore import Signal, Property, QPointF, Qt, QObject, Slot
from PySide6.QtGui import QPainterPath, QPainterPathStroker
from PySide6.QtQuick import QQuickItem


class MouseEvent(QObject):
    """
    Simple MouseEvent object, since QQuickMouseEvent is not accessible in the public API
    """
    def __init__(self, evt):
        super(MouseEvent, self).__init__()
        self._x = evt.position().x()
        self._y = evt.position().y()
        self._button = evt.button()
        self._modifiers = evt.modifiers()

    x = Property(float, lambda self: self._x, constant=True)
    y = Property(float, lambda self: self._y, constant=True)
    button = Property(Qt.MouseButton, lambda self: self._button, constant=True)
    modifiers = Property(Qt.KeyboardModifier, lambda self: self._modifiers, constant=True)


class EdgeMouseArea(QQuickItem):
    """
    Provides a MouseArea shaped as a cubic spline for mouse interaction with edges.
    Spline goes from (0,0) to (width, height). Works with negative values.
    """
    def __init__(self, parent=None):
        super(EdgeMouseArea, self).__init__(parent)

        self._curveScale = 0.7
        self._thickness = 2.0
        self._containsMouse = False
        self._path = None  # type: QPainterPath

        self.setAcceptHoverEvents(True)
        self.setAcceptedMouseButtons(Qt.AllButtons)

    def contains(self, point):
        return self.path().contains(point)

    def hoverEnterEvent(self, evt):
        self.setContainsMouse(True)
        super(EdgeMouseArea, self).hoverEnterEvent(evt)

    def hoverLeaveEvent(self, evt):
        self.setContainsMouse(False)
        super(EdgeMouseArea, self).hoverLeaveEvent(evt)

    def geometryChange(self, newGeometry, oldGeometry):
        super(EdgeMouseArea, self).geometryChange(newGeometry, oldGeometry)
        self.updateShape()

    def mousePressEvent(self, evt):
        if not self.acceptedMouseButtons() & evt.button():
            evt.setAccepted(False)
            return
        e = MouseEvent(evt)
        self.pressed.emit(e)
        e.deleteLater()

    def mouseReleaseEvent(self, evt):
        e = MouseEvent(evt)
        self.released.emit(e)
        e.deleteLater()

    def updateShape(self):
        # The outline is built on demand, by the hit tests: edges move far more often than they are hit
        self._path = None

    def path(self):
        if self._path is None:
            p1 = QPointF(0, 0)
            p2 = QPointF(self.width(), self.height())
            ctrlPt = QPointF(abs(self.width() * self.curveScale), 0)
            path = QPainterPath(p1)
            path.cubicTo(p1 + ctrlPt, p2 - ctrlPt, p2)

            # Outline of the curve stroked with the edge thickness: keeps a constant width along the curve
            stroker = QPainterPathStroker()
            stroker.setWidth(self._thickness)
            self._path = stroker.createStroke(path)
        return self._path

    def getThickness(self):
        return self._thickness

    def setThickness(self, value):
        if self._thickness == value:
            return
        self._thickness = value
        self.thicknessChanged.emit()
        self.updateShape()

    def getCurveScale(self):
        return self._curveScale

    def setCurveScale(self, value):
        if self.curveScale == value:
            return
        self._curveScale = value
        self.curveScaleChanged.emit()
        self.updateShape()

    def getContainsMouse(self):
        return self._containsMouse

    def setContainsMouse(self, value):
        if self._containsMouse == value:
            return
        self._containsMouse = value
        self.containsMouseChanged.emit()

    @Slot(QPointF, QPointF, result=bool)
    def intersectsSegment(self, p1, p2):
        """ Checks whether the given segment (p1, p2) intersects with the Path. """
        path = QPainterPath()
        # Starting point
        path.moveTo(p1)
        # Create a diagonal line to the other end of the rect
        path.lineTo(p2)
        v = self.path().intersects(path)
        return v

    thicknessChanged = Signal()
    thickness = Property(float, getThickness, setThickness, notify=thicknessChanged)
    curveScaleChanged = Signal()
    curveScale = Property(float, getCurveScale, setCurveScale, notify=curveScaleChanged)
    containsMouseChanged = Signal()
    containsMouse = Property(float, getContainsMouse, notify=containsMouseChanged)
    acceptedButtons = Property(int,
                               lambda self: super(EdgeMouseArea, self).acceptedMouseButtons,
                               lambda self, value: super(EdgeMouseArea, self).setAcceptedMouseButtons(Qt.MouseButtons(value)))

    pressed = Signal(MouseEvent)
    released = Signal(MouseEvent)
