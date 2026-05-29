pub struct Widget {
    value: i32,
}

pub struct Store<T> {
    value: T,
}

pub enum Mode {
    Fast,
    Slow,
}

impl Widget {
    pub fn new(value: i32) -> Self {
        Self { value }
    }
}

pub fn build_widget() -> Widget {
    Widget::new(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_widget() {
        let widget = build_widget();
        assert_eq!(widget.value, 1);
    }
}
