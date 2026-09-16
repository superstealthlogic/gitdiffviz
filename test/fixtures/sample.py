"""Fixture exercising the Python symbol shapes the extractor recognizes."""

from abc import ABC, abstractmethod
from contextlib import contextmanager
from dataclasses import dataclass

MAX_WIDGETS = 32
default_label = "widget"

type WidgetId = str


@dataclass
class Widget:
    name: str
    width: int = 1

    @property
    def area(self) -> int:
        return self.width

    @area.setter
    def area(self, value: int) -> None:
        self.width = value

    @staticmethod
    def unit() -> "Widget":
        return Widget(name="unit")

    @classmethod
    def from_name(cls, name: str) -> "Widget":
        return cls(name=name)


class Store(ABC):
    LIMIT = 8

    def __init__(self) -> None:
        self.items: list[Widget] = []

    @abstractmethod
    def persist(self, widget: Widget) -> None:
        ...

    async def fetch(self, widget_id: WidgetId) -> Widget:
        return Widget(name=widget_id)


def build(name: str) -> Widget:
    def normalize(value: str) -> str:
        return value.strip()

    return Widget(name=normalize(name))


async def build_all(names: list[str]) -> list[Widget]:
    return [build(name) for name in names]


def identity[T](value: T) -> T:
    return value


@contextmanager
def opened(path: str):
    yield path


class TestWidget:
    def test_area(self) -> None:
        assert Widget(name="a").area == 1


@pytest.mark.parametrize("name", ["a", "b"])
def test_build(name: str) -> None:
    assert build(name).name == name
