// Fixture exercising the TypeScript symbol shapes the extractor recognizes.

export const MAX_WIDGETS = 32;
const defaultLabel = "widget";

export type WidgetId = string;

export type Box<T> = { value: T };

export interface Widget {
  readonly id: WidgetId;
  width: number;
  resize(width: number): Widget;
}

export enum Mode {
  Compact,
  Wide,
}

export abstract class BaseStore<T> {
  protected readonly items: T[] = [];

  abstract persist(item: T): void;

  get size(): number {
    return this.items.length;
  }
}

export class Store extends BaseStore<Widget> {
  static empty = new Store();

  constructor(private readonly label: string = defaultLabel) {
    super();
  }

  persist(item: Widget): void {
    this.items.push(item);
  }

  set label_(value: string) {
    void value;
  }

  private describe = (item: Widget): string => `${this.label}:${item.id}`;

  async fetch(id: WidgetId): Promise<Widget> {
    return { id, width: 1, resize: (width) => ({ id, width, resize: this.noop }) };
  }

  private noop = (): never => {
    throw new Error("unreachable");
  };
}

export function build(id: WidgetId): Widget {
  function normalize(value: string): string {
    return value.trim();
  }

  return { id: normalize(id), width: 1, resize: () => build(id) };
}

export function* widgets(): Generator<Widget> {
  yield build("a");
}

export const resize = (widget: Widget, width: number): Widget => ({
  ...widget,
  width,
});

export declare function ambientBuild(id: WidgetId): Widget;

export namespace Widgets {
  export const UNIT: WidgetId = "unit";

  export function unit(): Widget {
    return build(UNIT);
  }
}
