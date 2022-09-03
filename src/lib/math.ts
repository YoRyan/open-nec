/** @noSelfInFile */

export type HiddenDigit = -1;

/**
 * Decomposes a number into its component digits for display in a digital gauge.
 * @param n The number to decompose. Must be non-negative.
 * @param width The number of places the gauge can display. Must be greater than
 * 0.
 * @returns The digits as an array of numbers, left-padded with -1, and a guide
 * value that indicates how many places to offset the number to the right.
 */
export function digits(n: number, width: number): [digits: (HiddenDigit | number)[], guide: number] {
    if (n < 0) {
        throw "digits number must be non-negative";
    } else if (width < 1) {
        throw "digits width must be 1 or greater";
    }
    const getDigits = getDigitsRecursively(n, width);
    let digits: number[] = [];
    for (let i = width - getDigits.length; i > 0; i--) {
        digits.push(-1 as HiddenDigit);
    }
    digits.push(...getDigits);
    return [digits, n === 0 ? 0 : Math.min(Math.floor(Math.log10(n)), width - 1)];
}

function getDigitsRecursively(n: number, width: number): number[] {
    return n <= 0 ? [0] : getDigitsRecursivelyB(n, width);
}

function getDigitsRecursivelyB(n: number, width: number): number[] {
    if (n <= 0 || width <= 0) {
        return [];
    } else {
        let rest = getDigitsRecursivelyB(Math.floor(n / 10), width - 1);
        rest.push(n % 10);
        return rest;
    }
}
