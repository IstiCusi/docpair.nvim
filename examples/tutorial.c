/**
 * # Clamp a value
 *
 * Keep a measurement inside its allowed interval.
 *
 * - Values below the minimum become the minimum.
 * - Values above the maximum become the maximum.
 * - Values already inside the interval are unchanged.
 *
 * | Input | Range | Result |
 * | --- | --- | --- |
 * | -2 | 0..10 | 0 |
 * | 5 | 0..10 | 5 |
 * | 12 | 0..10 | 10 |
 *
 * Open this file with :Documented! and press g then Tab in the right pane.
 */
double clamp(double value, double minimum, double maximum)
{
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}

/// # Linear interpolation
///
/// Move from a to b by fraction t. Values outside 0..1 extrapolate.
/// This is a second independently editable documentation section.
double interpolate(double a, double b, double t)
{
    /// Distance between the endpoints.
    double distance = b - a;
    return a + t * distance;
}
