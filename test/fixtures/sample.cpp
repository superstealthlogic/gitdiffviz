namespace demo {

enum Mode {
    Fast,
    Slow,
};

class Widget {
public:
    int value() const {
        return 1;
    }
};

template <typename T>
class Box {
public:
    T value() const {
        return value_;
    }

private:
    T value_;
};

template <typename T>
T identity(T value) {
    return value;
}

int build_widget() {
    Widget widget;
    return widget.value();
}

}
