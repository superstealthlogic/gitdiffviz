protocol Displayable {
    func display() -> String
}

enum Mode {
    case compact
    case expanded
}

struct Store<Value> {
    let value: Value
}

struct Widget {
    let value: Int

    init(value: Int) {
        self.value = value
    }

    func display() -> String {
        "\(value)"
    }
}

class Controller {
    var title: String = "Main"

    func render(widget: Widget) -> String {
        widget.display()
    }
}

extension Widget: Displayable {
    func mode() -> Mode {
        .compact
    }
}
