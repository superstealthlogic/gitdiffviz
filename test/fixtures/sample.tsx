// Fixture exercising JSX-bearing symbol shapes (also used for .jsx and .js).
import { useMemo, useState } from "react";

export interface PanelProps {
  title: string;
  widgets: string[];
}

export function Panel({ title, widgets }: PanelProps) {
  const [selected, setSelected] = useState<string | null>(null);

  const summary = useMemo(() => widgets.join(", "), [widgets]);

  return (
    <section>
      <h1>{title}</h1>
      <p>{summary}</p>
      <WidgetList items={widgets} onPick={setSelected} />
      <footer>{selected ?? "none"}</footer>
    </section>
  );
}

export const WidgetList = ({
  items,
  onPick,
}: {
  items: string[];
  onPick: (item: string) => void;
}) => (
  <ul>
    {items.map((item) => (
      <li key={item} onClick={() => onPick(item)}>
        {item}
      </li>
    ))}
  </ul>
);

export class Legend extends React.Component<{ label: string }> {
  render() {
    return <span className="legend">{this.props.label}</span>;
  }
}

function formatLabel(label: string): string {
  return label.toUpperCase();
}

export default Panel;
