/******
 * Handling amounts of money safely and efficiently.
 *
 * An amount of money is a number tagged with a currency id like "EUR"
 * or "USD". Precision and rounding mode can be chosen as template
 * parameters.
 *
 * If you write code which handles money, you have to choose a data type
 * for it. Out of the box, D offers you floating point, integer, and
 * std.bigint. All of these have their problems.
 *
 * Floating point is inherently imprecise. If your dollar numbers become
 * too big, then you start getting too much or too little cents. This
 * is not acceptable as the errors accumulate. Also, floating point has
 * values like "infinity" and "not a number" and if those show up,
 * usually things break, if you did not prepare for it. Debugging then
 * means to work backwards how this happened, which is tedious and hard.
 *
 * Integer numbers do not suffer from imprecision, but they can not
 * represent numbers as big as floating point. Worse, if your numbers
 * become too big, then your CPU silently wraps them into negative
 * numbers. Like the imprecision with floating point, your data is
 * now corrupted without anyone noticing it yet. Also, fixed point
 * arithmetic with integers is easy to get wrong and you need a
 * fractional part to represent cents, for example.
 *
 * As a third option, there is std.bigint, which provides numbers
 * with arbitrary precision. Like floating point, the arithmetic is easy.
 * Like integer, precision is fine. The downside is performance.
 * Nevertheless, from the three options, this is the most safe one.
 *
 * Can we do even better?
 * If we design a custom data type for money, we can improve safety
 * even more. For example, certain arithmetics can be forbidden. What
 * does it mean to multiply two money amounts, for example? There is no
 * such thing as $² which makes any sense. However, you can certainly
 * multiply a money amount with a unitless number. A custom data type
 * can precisely allow and forbid this operations.
 *
 * Here the design decision is to use an integer for the internal
 * representation. This limits the amounts you can use. For example,
 * if you decide to use 4 digits behind the comma, the maximum number
 * is 922,337,203,685,477.5807 or roughly 922 trillion. The US debt is
 * currently in the trillions, so there are certainly cases where
 * this representation is not applicable. However, we can check overflow,
 * so if it happens, you get an exception thrown and notice it
 * right away. The upside of using an integer is performance and
 * a deterministic arithmetic all programmers are familiar with.
 *
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Andreas Zwinkau
 */
module money;

import std.math : floor, ceil, lrint, abs, FloatingPointControl;
import std.conv : to;
import core.checkedint : adds, subs, muls, negs;
import std.format : FormatSpec, formattedWrite;
import std.traits : hasMember;

@nogc pure @safe nothrow private long pow10(int x)
{
    if (x <= 0)
        return 1;
    return 10 * pow10(x - 1);
}

pure @safe nothrow private string decimals_format(int x)()
{
    import std.conv : text;

    return "%0" ~ text(x) ~ "d";
}

/** Holds an amount of currency **/
struct currency(string currency_name, int dec_places = 4, roundingMode rmode = roundingMode.HALF_UP)
{
    alias T = typeof(this);
    enum __currency = currency_name;
    enum __dec_places = dec_places;
    enum __rmode = rmode;
    long amount;

    /// Floating point contructor. Uses rmode on x.
    this(double x)
    {
        amount = to!long(round(x * pow10(dec_places), rmode));
    }

    /** String contructor.
      *
      * Throws: ParseError or std.conv.ConvOverflowException for invalid inputs
      */
    this(string x)
    {
        import std.regex;
        import std.stdio;

        auto match = matchFirst(x, ctRegex!"([0-9]+).?([0-9]*)");
        if (match.length == 0)
            throw new ParseError("Does not start with digit: " ~ x);
        long integer = match[1].to!long;
        long decimals;
        if (match[2] != "")
            decimals = match[2].to!long;
        if (long.max / pow10(dec_places) < integer)
            throw new ParseError("Number too large: " ~ x);
        auto dec_amount = decimals * pow10(cast(int)(dec_places - match[2].length));
        amount = integer * pow10(dec_places) + dec_amount;
    }

    private static T fromLong(long a)
    {
        T ret = void;
        ret.amount = a;
        return ret;
    }

    /// default initialisation value is zero
    static immutable init = fromLong(0L);
    /// maximum amount depends on dec_places
    static immutable max = fromLong(long.max);
    /// minimum amount depends on dec_places
    static immutable min = fromLong(long.min);

    private static immutable dec_mask = pow10(dec_places);

    /// Can add and subtract money amounts of the same type.
    T opBinary(string op)(const T rhs) const
    {
        static if (op == "+")
        {
            bool overflow;
            auto ret = fromLong(adds(amount, rhs.amount, overflow));
            if (overflow)
                throw new OverflowException();
            return ret;
        }
        else static if (op == "-")
        {
            bool overflow;
            auto ret = fromLong(subs(amount, rhs.amount, overflow));
            if (overflow)
                throw new OverflowException();
            return ret;
        }
        else
            static assert(0, "Operator " ~ op ~ " not implemented");
    }

    /// Can multiply, divide, and modulo with integer values.
    T opBinary(string op)(const long rhs) const
    {
        static if (op == "*")
        {
            bool overflow;
            auto ret = fromLong(muls(amount, rhs, overflow));
            if (overflow)
                throw new OverflowException();
            return ret;
        }
        else static if (op == "/")
        {
            return fromLong(amount / rhs);
        }
        else static if (op == "%")
        {
            const intpart = amount / pow10(dec_places);
            return fromLong(intpart % rhs * pow10(dec_places));
        }
        else
            static assert(0, "Operator " ~ op ~ " not implemented");
    }

    /// Can multiply, divide, and modulo floating point numbers.
    T opBinary(string op)(const real rhs) const
    {
        static if (op == "*")
        {
            const converted = T(rhs);
            bool overflow = false;
            const result = muls(amount, converted.amount, overflow);
            if (overflow)
                throw new OverflowException();
            return fromLong(result / pow10(dec_places));
        }
        else static if (op == "/")
        {
            const converted = T(rhs);
            bool overflow = false;
            auto mult = muls(amount, pow10(dec_places), overflow);
            if (overflow)
                throw new OverflowException();
            return fromLong(mult / converted.amount);
        }
        else static if (op == "%")
        {
            const converted = T(rhs);
            return fromLong(amount % converted.amount);
        }
        else
            static assert(0, "Operator " ~ op ~ " not implemented");
    }

    /// Can add and subtract money amounts of the same type.
    void opOpAssign(string op)(const T rhs)
    {
        static if (op == "+")
        {
            bool overflow;
            auto ret = adds(amount, rhs.amount, overflow);
            if (overflow)
                throw new OverflowException();
            amount = ret;
        }
        else static if (op == "-")
        {
            bool overflow;
            auto ret = subs(amount, rhs.amount, overflow);
            if (overflow)
                throw new OverflowException();
            amount = ret;
        }
        else
            static assert(0, "Operator " ~ op ~ " not implemented");
    }

    /// Can multiply, divide, and modulo with integer values.
    void opOpAssign(string op)(const long rhs)
    {
        static if (op == "*")
        {
            bool overflow;
            auto ret = muls(amount, rhs, overflow);
            if (overflow)
                throw new OverflowException();
            amount = ret;
        }
        else static if (op == "/")
        {
            amount /= rhs;
        }
        else static if (op == "%")
        {
            const intpart = amount / pow10(dec_places);
            amount = intpart % rhs * pow10(dec_places);
        }
        else
            static assert(0, "Operator " ~ op ~ " not implemented");
    }

    /// Can multiply, divide, and modulo floating point numbers.
    void opOpAssign(string op)(const real rhs)
    {
        static if (op == "*")
        {
            const converted = T(rhs);
            bool overflow = false;
            const result = muls(amount, converted.amount, overflow);
            if (overflow)
                throw new OverflowException();
            amount = result / pow10(dec_places);
        }
        else static if (op == "/")
        {
            const converted = T(rhs);
            bool overflow = false;
            auto mult = muls(amount, pow10(dec_places), overflow);
            if (overflow)
                throw new OverflowException();
            amount = mult / converted.amount;
        }
        else static if (op == "%")
        {
            const converted = T(rhs);
            amount = amount % converted.amount;
        }
        else
            static assert(0, "Operator " ~ op ~ " not implemented");
    }

    /// Can check equality with money amounts of the same concurrency and decimal places.
    bool opEquals(OT)(auto ref const OT other) const 
            if (isCurrency!OT && other.__currency == currency_name
                && other.__dec_places == dec_places)
    {
        return other.amount == amount;
    }

    /// Can compare with money amounts of the same concurrency.
    int opCmp(OT)(const OT other) const 
            if (isCurrency!OT && other.__currency == currency_name)
    {
        static if (dec_places == other.__dec_places)
        {
            if (other.amount > this.amount)
                return -1;
            if (other.amount < this.amount)
                return 1;
            return 0;
        }
        else static if (dec_places < other.__dec_places)
        {
            /* D implicitly makes this work for case '>' */
            auto nthis = this * pow10(other.__dec_places - dec_places);
            /* overflow check included */
            if (other.amount > nthis.amount)
                return -1;
            if (other.amount < nthis.amount)
                return 1;
            return 0;
        }
        else
            static assert(0, "opCmp with such 'other' not implemented");
    }

    void toDecimalString(scope void delegate(const(char)[]) sink, FormatSpec!char fmt) const
    {
        formattedWrite(sink, "%d", (amount / dec_mask));
        sink(".");
        auto decimals = amount % dec_mask;
        if (fmt.precision < dec_places)
        {
            auto n = dec_places - fmt.precision;
            decimals = round!(rmode)(decimals, n);
            decimals = decimals / pow10(n);
            import std.conv : text;

            formattedWrite(sink, "%0" ~ text(fmt.precision) ~ "d", decimals);
        }
        else
        {
            formattedWrite(sink, decimals_format!dec_places(), decimals);
        }
    }

    /// Can convert to string.
    void toString(scope void delegate(const(char)[]) sink, FormatSpec!char fmt) const
    {
        switch (fmt.spec)
        {
        case 's': /* default e.g. for writeln */
            goto case;
        case 'f':
	        toDecimalString(sink, fmt);
            sink(currency_name);
            break;
        case 'F':
	        toDecimalString(sink, fmt);
            break;
        case 'd':
            auto ra = round!rmode(amount, dec_places);
            formattedWrite(sink, "%d", (ra / dec_mask));
            sink(currency_name);
            break;
        default:
            throw new Exception("Unknown format specifier: %" ~ fmt.spec);
        }
    }
}

/// Basic usage
unittest
{
    alias EUR = currency!("EUR");
    assert(EUR(100.0001) == EUR(100.00009));
    assert(EUR(3.10) + EUR(1.40) == EUR(4.50));
    assert(EUR(3.10) - EUR(1.40) == EUR(1.70));
    assert(EUR(10.01) * 1.1 == EUR(11.011));

    import std.format : format;

    // for writefln("%d", EUR(3.6));
    assert(format("%d", EUR(3.6)) == "4EUR");
    assert(format("%d", EUR(3.1)) == "3EUR");
    // for writefln("%f", EUR(3.141592));
    assert(format("%f", EUR(3.141592)) == "3.1416EUR");
    assert(format("%.2f", EUR(3.145)) == "3.15EUR");
    // From issue #5
    assert(format("%.4f", EUR(0.01234)) == "0.0123EUR");
    
    assert(format("%F", EUR(3.141592)) == "3.1416");
}

/// Overflow is an error, since silent corruption is worse
@safe unittest
{
    import std.exception : assertThrown;

    alias EUR = currency!("EUR");
    auto one = EUR(1);
    assertThrown!OverflowException(EUR.max + one);
    assertThrown!OverflowException(EUR.min - one);
}

/// Arithmetic ignores rounding mode
@safe unittest
{
    alias EUR = currency!("EUR", 2, roundingMode.UP);
    auto one = EUR(1);
    assert(one != one / 3);
}

/// Generic equality and order
@safe unittest
{
    alias USD = currency!("USD", 2);
    alias EURa = currency!("EUR", 2);
    alias EURb = currency!("EUR", 4);
    alias EURc = currency!("EUR", 4, roundingMode.DOWN);
    // cannot compile with different currencies
    static assert(!__traits(compiles, EURa(1) == USD(1)));
    // cannot compile with different dec_places
    static assert(!__traits(compiles, EURa(1) == EURb(1)));
    // can check equality if only rounding mode differs
    assert(EURb(1.01) == EURc(1.01));
    // cannot compare with different currencies
    static assert(!__traits(compiles, EURa(1) < USD(1)));
}

// TODO Using negative dec_places for big numbers?
//@nogc @safe unittest
//{
//    alias USD = currency!("USD", -6);
//    assert(USD(1_000_000.00) == USD(1_100_000.));
//}

enum isCurrency(T) = (hasMember!(T, "amount") && hasMember!(T,
            "__dec_places") && hasMember!(T, "__rmode"));
static assert(isCurrency!(currency!"EUR"));

// TODO @safe (due to std.format.format)
unittest
{
    alias EUR = currency!("EUR");
    import std.format : format;

    assert(format("%s", EUR(3.1)) == "3.1000EUR");

    import std.exception : assertThrown;

    assertThrown!Exception(format("%x", EUR(3.1)));
}

@safe unittest
{
    alias EUR = currency!("EUR");
    assert(EUR(5) < EUR(6));
    assert(EUR(6) > EUR(5));
    assert(EUR(5) >= EUR(5));
    assert(EUR(5) == EUR(5));
    assert(EUR(6) != EUR(5));

    import std.exception : assertThrown;

    assertThrown!OverflowException(EUR.max * 2);
    assertThrown!OverflowException(EUR.max * 2.0);
}

@safe unittest
{
    alias EUR = currency!("EUR");
    auto x = EUR(42);
    assert(EUR(84) == x * 2);
    static assert(!__traits(compiles, x * x));
    assert(EUR(21) == x / 2);
    assert(EUR(2) == x % 4);
}

@safe unittest
{
    alias EURa = currency!("EUR", 2);
    alias EURb = currency!("EUR", 4);
    auto x = EURa(1.01);
    assert(x > EURb(1.0001));
    assert(x < EURb(1.0101));
    assert(x <= EURb(1.01));
}

@safe unittest
{
    alias EUR = currency!("EUR");
    auto x = EUR(2.22);
    x += EUR(2.22);
    assert(x == EUR(4.44));
    x -= EUR(3.33);
    assert(x == EUR(1.11));
    x *= 4;
    assert(x == EUR(4.44));
    x /= 2;
    assert(x == EUR(2.22));
    x *= 2.0;
    assert(x == EUR(4.44));
    x /= 2.0;
    assert(x == EUR(2.22));
    x %= 3.0;
    assert(x == EUR(2.22));
    x %= 3;
    assert(x == EUR(2));
}

@safe unittest
{
    import std.exception : assertThrown;

    alias EUR = currency!("EUR");
    EUR x = EUR.max;
    EUR y = EUR.min;
    assertThrown!OverflowException(x += EUR(1));
    assert(x == EUR.max);
    assertThrown!OverflowException(y -= EUR(1));
    assert(y == EUR.min);
    assertThrown!OverflowException(x *= 2);
    assert(x == EUR.max);
    assertThrown!OverflowException(x *= 2.0);
    assert(x == EUR.max);
    assertThrown!OverflowException(y /= 10.0);
    assert(y == EUR.min);
}

/** Specifies rounding behavior **/
enum roundingMode
{
    // dfmt off
    /** Round upwards, e.g. 3.1 up to 4. */
    UP,
    /** Round downwards, e.g. 3.9 down to 3. */
    DOWN,
    /** Round to nearest number, half way between round up, e.g. 3.5 to 4. */
    HALF_UP,
    /** Round to nearest number, half way between round dow, e.g. 3.5 to 3.  */
    HALF_DOWN,
    /** Round to nearest number, half way between round to even number, e.g. 3.5 to 4. */
    HALF_EVEN,
    /** Round to nearest number, half way between round to odd number, e.g. 3.5 to 3. */
    HALF_ODD,
    /** Round to nearest number, half way between round towards zero, e.g. -3.5 to -3.  */
    HALF_TO_ZERO,
    /** Round to nearest number, half way between round away from zero, e.g. -3.5 to -4.  */
    HALF_FROM_ZERO,
    /** Throw exception if rounding would be necessary */
    UNNECESSARY
    // dfmt on
}

/** Round an integer to a certain decimal place according to rounding mode */
long round(roundingMode m)(long x, int dec_place)
out (result)
{
    assert((result % pow10(dec_place)) == 0);
}
body
{
    const zeros = pow10(dec_place);
    /* short cut, also removes edge cases */
    if ((x % zeros) == 0)
        return x;

    const half = zeros / 2;
    with (roundingMode)
    {
        static if (m == UP)
        {
            return ((x / zeros) + 1) * zeros;
        }
        else static if (m == DOWN)
        {
            return x / zeros * zeros;
        }
        else static if (m == HALF_UP)
        {
            if ((x % zeros) >= half)
                return ((x / zeros) + 1) * zeros;
            else
                return x / zeros * zeros;
        }
        else static if (m == HALF_DOWN)
        {
            if ((x % zeros) > half)
                return ((x / zeros) + 1) * zeros;
            else
                return x / zeros * zeros;
        }
        else static if (m == HALF_EVEN)
        {
            const down = x / zeros;
            if (down % 2 == 0)
                return down * zeros;
            else
                return (down + 1) * zeros;
        }
        else static if (m == HALF_ODD)
        {
            const down = x / zeros;
            if (down % 2 == 0)
                return (down + 1) * zeros;
            else
                return down * zeros;
        }
        else static if (m == HALF_TO_ZERO)
        {
            const down = x / zeros;
            if (down < 0)
            {
                if (abs(x % zeros) <= half)
                {
                    return (down) * zeros;
                }
                else
                {
                    return (down - 1) * zeros;
                }
            }
            else
            {
                if ((x % zeros) > half)
                {
                    return (down + 1) * zeros;
                }
                else
                {
                    return (down) * zeros;
                }
            }
        }
        else static if (m == HALF_FROM_ZERO)
        {
            const down = x / zeros;
            if (down < 0)
            {
                if (abs(x % zeros) < half)
                {
                    return (down) * zeros;
                }
                else
                {
                    return (down - 1) * zeros;
                }
            }
            else
            {
                if (x % zeros >= half)
                {
                    return (down + 1) * zeros;
                }
                else
                {
                    return (down) * zeros;
                }
            }
        }
        else static if (m == UNNECESSARY)
        {
            throw new ForbiddenRounding();
        }
    }
}

// dfmt off
///
@nogc @safe unittest
{
    assert (round!(roundingMode.DOWN)     (1009, 1) == 1000);
    assert (round!(roundingMode.UP)       (1001, 1) == 1010);
    assert (round!(roundingMode.HALF_UP)  (1005, 1) == 1010);
    assert (round!(roundingMode.HALF_DOWN)(1005, 1) == 1000);
}
// dfmt on

@safe pure @nogc nothrow unittest
{
    // dfmt off
    assert (round!(roundingMode.HALF_UP)       ( 10, 1) ==  10);
    assert (round!(roundingMode.UP)            ( 11, 1) ==  20);
    assert (round!(roundingMode.DOWN)          ( 19, 1) ==  10);
    assert (round!(roundingMode.HALF_UP)       ( 15, 1) ==  20);
    assert (round!(roundingMode.HALF_UP)       (-15, 1) == -10);
    assert (round!(roundingMode.HALF_DOWN)     ( 15, 1) ==  10);
    assert (round!(roundingMode.HALF_DOWN)     ( 16, 1) ==  20);
    assert (round!(roundingMode.HALF_EVEN)     ( 15, 1) ==  20);
    assert (round!(roundingMode.HALF_EVEN)     ( 25, 1) ==  20);
    assert (round!(roundingMode.HALF_ODD)      ( 15, 1) ==  10);
    assert (round!(roundingMode.HALF_ODD)      ( 25, 1) ==  30);
    assert (round!(roundingMode.HALF_TO_ZERO)  ( 25, 1) ==  20);
    assert (round!(roundingMode.HALF_TO_ZERO)  ( 26, 1) ==  30);
    assert (round!(roundingMode.HALF_TO_ZERO)  (-25, 1) == -20);
    assert (round!(roundingMode.HALF_TO_ZERO)  (-26, 1) == -30);
    assert (round!(roundingMode.HALF_FROM_ZERO)( 25, 1) ==  30);
    assert (round!(roundingMode.HALF_FROM_ZERO)( 24, 1) ==  20);
    assert (round!(roundingMode.HALF_FROM_ZERO)(-25, 1) == -30);
    assert (round!(roundingMode.HALF_FROM_ZERO)(-24, 1) == -20);
    // dfmt on
}

@safe unittest
{
    import std.exception : assertThrown;

    assert(round!(roundingMode.UNNECESSARY)(10, 1) == 10);
    assertThrown!ForbiddenRounding(round!(roundingMode.UNNECESSARY)(12, 1) == 10);
}

/** Round a float to an integer according to rounding mode */
// TODO pure nothrow @nogc (Phobos...)
real round(real x, roundingMode m) @trusted
{
    FloatingPointControl fpctrl;
    final switch (m) with (roundingMode)
    {
    case UP:
        return ceil(x);
    case DOWN:
        return floor(x);
    case HALF_UP:
        return lrint(x);
    case HALF_DOWN:
        fpctrl.rounding = FloatingPointControl.roundDown;
        return lrint(x);
    case HALF_TO_ZERO:
        fpctrl.rounding = FloatingPointControl.roundToZero;
        return lrint(x);
    case HALF_EVEN:
    case HALF_ODD:
    case HALF_FROM_ZERO:
    case UNNECESSARY:
        throw new ForbiddenRounding();
    }
}

@safe unittest
{
    assert(round(3.5, roundingMode.HALF_DOWN) == 3.0);
    assert(round(3.8, roundingMode.HALF_TO_ZERO) == 3.0);

    import std.exception : assertThrown;

    assertThrown!ForbiddenRounding(round(3.1, roundingMode.UNNECESSARY));
    assertThrown!ForbiddenRounding(round(3.1, roundingMode.HALF_EVEN));
    assertThrown!ForbiddenRounding(round(3.1, roundingMode.HALF_ODD));
    assertThrown!ForbiddenRounding(round(3.1, roundingMode.HALF_FROM_ZERO));
}

/** Exception is thrown if rounding would have to happen,
    but roundingMode.UNNECESSARY is specified. */
class ForbiddenRounding : Exception
{
    public
    {
        @safe pure nothrow this(string file = __FILE__, size_t line = __LINE__, Throwable next = null)
        {
            super("Rounding is forbidden", file, line, next);
        }
    }
}

/** Overflow can happen with money arithmetic. */
class OverflowException : Exception
{
    public
    {
        @safe pure nothrow this(string file = __FILE__, size_t line = __LINE__, Throwable next = null)
        {
            super("Overflow", file, line, next);
        }
    }
}

/** Failure to parse a money amount from string */
class ParseError : Exception
{
    public
    {
        @safe pure nothrow this(string file = __FILE__, size_t line = __LINE__, Throwable next = null)
        {
            super("Parse error", file, line, next);
        }
    }
}

unittest
{
    import std.exception : assertThrown;
    import std.format : format;
    import std.conv : ConvOverflowException;

    alias EUR = currency!("EUR");
    assertThrown!ParseError(EUR("foo"));
    assertThrown!ParseError(EUR("999999999999999999"));
    assertThrown!ConvOverflowException(EUR("9999999999999999999999"));
    EUR x = EUR("123.45");
    EUR y = EUR("123");

    assert(format("%f", x) == "123.4500EUR");
    assert(format("%.1f", x) == "123.5EUR");
    assert(format("%f", y) == "123.0000EUR");
}
