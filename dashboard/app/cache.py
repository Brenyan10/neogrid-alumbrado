"""Caché en memoria con caducidad (los datos de la nube son una copia estática)."""
import threading
import time
from collections import OrderedDict

from . import config

_datos: "OrderedDict[tuple, tuple[float, object]]" = OrderedDict()
_candado = threading.Lock()
_MAX = 400


def obtener(clave: tuple, calcular, segundos: int | None = None):
    ahora = time.monotonic()
    with _candado:
        item = _datos.get(clave)
        if item and item[0] > ahora:
            _datos.move_to_end(clave)
            return item[1]
    valor = calcular()
    with _candado:
        _datos[clave] = (ahora + (segundos or config.CACHE_SEGUNDOS), valor)
        _datos.move_to_end(clave)
        while len(_datos) > _MAX:
            _datos.popitem(last=False)
    return valor


def limpiar() -> None:
    with _candado:
        _datos.clear()
