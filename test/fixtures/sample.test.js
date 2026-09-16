// Fixture exercising jest/vitest suite and case blocks in plain JavaScript.
import { build, resize } from "./sample";

const BASE_WIDTH = 1;

describe("build", () => {
  it("normalizes the id", () => {
    expect(build(" a ").id).toBe("a");
  });

  test("keeps the base width", () => {
    expect(build("a").width).toBe(BASE_WIDTH);
  });

  describe("resize", () => {
    it.each([2, 3])("applies %i", (width) => {
      expect(resize(build("a"), width).width).toBe(width);
    });
  });
});

export function makeWidget(id) {
  return build(id);
}
