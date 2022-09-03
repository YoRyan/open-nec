import { digits } from "../lib/math";

test("decompose a 3-digit number with 3 places", () => {
    expect(digits(123, 3)).toStrictEqual([[1, 2, 3], 2]);
});

test("decompose a 2-digit number with 3 places", () => {
    expect(digits(24, 3)).toStrictEqual([[-1, 2, 4], 1]);
});

test("decompose a 1-digit number with 3 places", () => {
    expect(digits(7, 3)).toStrictEqual([[-1, -1, 7], 0]);
});

test("decompose a zero with 3 places", () => {
    expect(digits(0, 3)).toStrictEqual([[-1, -1, 0], 0]);
});

test("decompose a 4-digit number with 3 places", () => {
    expect(digits(4021, 3)).toStrictEqual([[0, 2, 1], 2]);
});
