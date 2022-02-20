# @version 0.3.1

interface ERC20:
    def transfer(_to: address, _value: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable
    def decimals() -> uint256: view
    def balanceOf(_user: address) -> uint256: view

MAX_INT: constant(int256) = 57896044618658097711785492504343953926634992332820282019728792003956564819967  # 2**255 - 1
MAX_TICKS: constant(int256) = 50

struct UserTicks:
    ns: bytes32  # packs n1 and n2, each is int128
    ticks: uint256[MAX_TICKS/2]  # Share fractions packed 2 per slot

struct DetailedTrade:
    in_amount: uint256
    out_amount: uint256
    n1: int256
    n2: int256
    ticks_in: uint256[MAX_TICKS]
    last_tick_j: uint256

ADMIN: immutable(address)
A: immutable(uint256)
SQRT_BAND_RATIO: immutable(uint256)  # sqrt(A / (A - 1))
COLLATERAL_TOKEN: immutable(address)  # y
BORROWED_TOKEN: immutable(address)    # x
COLLATERAL_PRECISION: immutable(uint256)
BORROWED_PRECISION: immutable(uint256)

fee: public(uint256)
rate: public(int256)  # Rate can be negative, to support positive-rebase tokens
base_price_0: uint256
base_price_time: uint256
active_band: public(int256)

price_oracle_sig: uint256

p_base_mul: uint256

bands_x: public(HashMap[int256, uint256])
bands_y: public(HashMap[int256, uint256])

total_shares: public(HashMap[int256, uint256])
user_shares: public(HashMap[address, UserTicks])


@external
def __init__(_collateral_token: address, _borrowed_token: address,
             _A: uint256, _base_price: uint256, fee: uint256,
             _admin: address,
             _price_oracle_contract:address, _price_oracle_sig: bytes32):
    A = _A
    self.base_price_0 = _base_price
    self.base_price_time = block.timestamp
    self.p_base_mul = 10**18
    COLLATERAL_TOKEN = _collateral_token
    BORROWED_TOKEN = _borrowed_token
    COLLATERAL_PRECISION = 10 ** (18 - ERC20(_collateral_token).decimals())
    BORROWED_PRECISION = 10 ** (18 - ERC20(_borrowed_token).decimals())
    self.fee = fee
    ADMIN = _admin

    self.price_oracle_sig = bitwise_or(
        shift(convert(_price_oracle_contract, uint256), 32),
        convert(_price_oracle_sig, uint256)
    )

    # Vyper cannot call functions from init
    # So we repeat sqrt here. SAD
    _x: uint256 = 10**18 * _A / (_A - 1)
    _z: uint256 = (_x + 10**18) / 2
    _y: uint256 = _x
    for i in range(256):
        if _z == _y:
            break
        _y = _z
        _z = (_x * 10**18 / _z + _z) / 2
    SQRT_BAND_RATIO = _y
    # end of sqrt calc


# Low-level math
@internal
@pure
def sqrt_int(x: uint256) -> uint256:
    """
    Originating from: https://github.com/vyperlang/vyper/issues/1266
    """

    if x == 0:
        return 0

    z: uint256 = (x + 10**18) / 2
    y: uint256 = x

    for i in range(256):
        if z == y:
            return y
        y = z
        z = (x * 10**18 / z + z) / 2

    raise "Did not converge"
# End of low-level math


@external
@view
def price_oracle_signature() -> (address, Bytes[4]):
    sig: uint256 = self.price_oracle_sig
    return convert(shift(sig, -32), address), slice(convert(bitwise_and(sig, 2**32-1), bytes32), 28, 4)


@internal
@view
def _price_oracle() -> uint256:
    sig: uint256 = self.price_oracle_sig
    response: Bytes[32] = raw_call(
        convert(shift(sig, -32), address),
        slice(convert(bitwise_and(sig, 2**32-1), bytes32), 28, 4),
        is_static_call=True,
        max_outsize=32
    )
    return convert(response, uint256)


@external
@view
def price_oracle() -> uint256:
    return self._price_oracle()


@external
@view
def coins(i: uint256) -> address:
    if i == 0:
        return BORROWED_TOKEN
    elif i == 1:
        return COLLATERAL_TOKEN
    else:
        raise "Out of range"


@external
@view
def A() -> uint256:
    return A


@internal
@view
def _base_price() -> uint256:
    """
    Base price grows with time to account for interest rate (which is 0 by default)
    """
    return convert(
        convert(self.base_price_0, int256) + self.rate * convert(block.timestamp - self.base_price_time, int256) / 10**18,
        uint256)


@external
@view
def base_price() -> uint256:
    return self._base_price()


@internal
@view
def _p_oracle_band(n: int256, is_down: bool) -> uint256:
    # k = (self.A - 1) / self.A  # equal to (p_up / p_down)
    # return self.p_base * k ** n
    n_active: int256 = self.active_band
    p_base: uint256 = self._base_price() * self.p_base_mul / 10**18
    band_distance: int256 = abs(n - n_active)

    # k = (self.A - 1) / self.A  # equal to (p_up / p_down)
    # p_base = self.p_base * k ** (n_band + 1)
    for i in range(1000):
        if i == band_distance:
            break
        if n > n_active:
            p_base = p_base * (A - 1) / A
        else:
            p_base = p_base * A / (A - 1)
    if is_down:
        p_base = p_base * (A - 1) / A

    return p_base


@internal
@view
def _p_current_band(n: int256, is_up: bool) -> uint256:
    """
    Upper or lower price of the band `n` at current `p_oracle`
    """
    # k = (self.A - 1) / self.A  # equal to (p_up / p_down)
    # p_base = self.p_base * k ** (n_band + 1)
    p_base: uint256 = self._p_oracle_band(n, is_up)

    # return self.p_oracle**3 / p_base**2
    p_oracle: uint256 = self._price_oracle()
    return p_oracle**2 / p_base * p_oracle / p_base


@external
@view
def p_current_up(n: int256) -> uint256:
    """
    Upper price of the band `n` at current `p_oracle`
    """
    return self._p_current_band(n, True)


@external
@view
def p_current_down(n: int256) -> uint256:
    """
    Lower price of the band `n` at current `p_oracle`
    """
    return self._p_current_band(n, False)


@external
@view
def p_oracle_up(n: int256) -> uint256:
    """
    Upper price of the band `n` when `p_oracle` == `p`
    """
    return self._p_oracle_band(n, False)


@external
@view
def p_oracle_down(n: int256) -> uint256:
    """
    Lower price of the band `n` when `p_oracle` == `p`
    """
    return self._p_oracle_band(n, True)


@internal
@view
def _get_y0(x: uint256, y: uint256, p_o: uint256, p_o_up: uint256) -> uint256:
    # solve:
    # p_o * A * y0**2 - y0 * (p_oracle_up/p_o * (A-1) * x + p_o**2/p_oracle_up * A * y) - xy = 0
    b: uint256 = p_o_up * (A - 1) * x / p_o + A * p_o**2 / p_o_up * y / 10**18
    D: uint256 = b**2 + (4 * A) * p_o * y / 10**18 * x
    return (b + self.sqrt_int(D / 10**18)) * 10**18 / ((2 * A) * p_o)


@external
@view
def get_y0(n: int256) -> uint256:
    x: uint256 = self.bands_x[n]
    y: uint256 = self.bands_y[n]
    p_o: uint256 = self._price_oracle()
    p_oracle_up: uint256 = 0
    if n == MAX_INT:
        p_oracle_up = self._base_price() * self.p_base_mul / 10**18
    else:
        p_oracle_up = self._p_oracle_band(n, False)

    return self._get_y0(x, y, p_o, p_oracle_up)


@internal
@view
def _get_p(y0: uint256) -> uint256:
    n: int256 = self.active_band
    x: uint256 = self.bands_x[self.active_band]
    y: uint256 = self.bands_y[self.active_band]
    p_o_up: uint256 = self._base_price() * self.p_base_mul / 10**18
    if x == 0 and y == 0:
        return p_o_up * 10**18 / SQRT_BAND_RATIO
    p_o: uint256 = self._price_oracle()

    _y0: uint256 = y0
    if _y0 == MAX_UINT256:
        _y0 = self._get_y0(x, y, p_o, p_o_up)

    # (f(y0) + x) / (g(y0) + y)
    f: uint256 = A * _y0 * p_o / p_o_up * p_o
    g: uint256 = (A - 1) * _y0 * p_o_up / p_o
    return (f + x * 10**18) / (g + y)


@external
@view
def get_p() -> uint256:
    return self._get_p(MAX_UINT256)


@internal
def save_user_ticks(user: address, n1: int256, n2: int256, ticks: uint256[MAX_TICKS], save_n: bool):
    """
    Packs and saves user ticks
    """
    if save_n:
        n1p: uint256 = convert(convert(convert(n1, int128), bytes32), uint256)
        n2p: uint256 = convert(convert(convert(n2, int128), bytes32), uint256)
        if n1 > n2:
            self.user_shares[user].ns = convert(bitwise_or(n2p, shift(n1p, 128)), bytes32)
        else:
            self.user_shares[user].ns = convert(bitwise_or(n1p, shift(n2p, 128)), bytes32)

    dist: uint256 = convert(abs(n1 - n2), uint256) + 1
    ptr: uint256 = 0
    for i in range(MAX_TICKS / 2):
        if ptr >= dist:
            break
        tick: uint256 = ticks[ptr]
        ptr += 1
        if dist != ptr:
            tick = bitwise_or(tick, shift(ticks[ptr], 128))
        ptr += 1
        self.user_shares[user].ticks[i] = tick


@internal
@view
def has_liquidity(user: address) -> bool:
    return self.user_shares[user].ticks[0] != 0


@internal
def empty_ticks(user: address):
    self.user_shares[user].ticks[0] = 0


@internal
@view
def _read_user_tick_numbers(user: address) -> int256[2]:
    """
    Unpacks and reads user tick numbers
    """
    ns: uint256 = convert(self.user_shares[user].ns, uint256)
    n1: int256 = convert(convert(convert(bitwise_and(ns, 2**128 - 1), bytes32), int128), int256)
    n2: int256 = convert(convert(convert(shift(ns, -128), bytes32), int128), int256)
    return [n1, n2]


@external
@view
def read_user_tick_numbers(user: address) -> int256[2]:
    return self._read_user_tick_numbers(user)


@internal
@view
def _read_user_ticks(user: address, size: int256) -> uint256[MAX_TICKS]:
    """
    Unpacks and reads user ticks
    """
    ticks: uint256[MAX_TICKS] = empty(uint256[MAX_TICKS])
    ptr: int256 = 0
    for i in range(MAX_TICKS / 2):
        if ptr > size:
            break
        tick: uint256 = self.user_shares[user].ticks[i]
        ticks[ptr] = bitwise_and(tick, 2**128 - 1)
        ptr += 1
        if ptr != size:
            ticks[ptr] = shift(tick, -128)
        ptr += 1
    return ticks


@external
@view
def read_user_ticks(user: address, size: int256) -> uint256[MAX_TICKS]:
    return self._read_user_ticks(user, size)


@external
def deposit_range(user: address, amount: uint256, n1: int256, n2: int256, move_coins: bool):
    assert msg.sender == ADMIN

    n0: int256 = self.active_band
    assert n1 > n0 and n2 > n0, "Deposits should be below current band"
    if move_coins:
        assert ERC20(COLLATERAL_TOKEN).transferFrom(user, self, amount)

    band: int256 = min(n1, n2)
    finish: int256 = max(n1, n2)

    y: uint256 = amount * COLLATERAL_PRECISION / (convert(finish - band, uint256) + 1)
    assert y > 0, "Amount too low"

    save_n: bool = True
    if self.has_liquidity(user):
        ns: int256[2] = self._read_user_tick_numbers(user)
        assert ns[0] == band and ns[1] == finish, "Wrong range"
        save_n = False

    user_shares: uint256[MAX_TICKS] = empty(uint256[MAX_TICKS])

    for i in range(MAX_TICKS):
        # Deposit coins
        assert self.bands_x[band] == 0, "Band not empty"
        total_y: uint256 = self.bands_y[band]
        self.bands_y[band] = total_y + y
        # Total / user share
        s: uint256 = self.total_shares[band]
        if s == 0:
            s = y
            user_shares[i] = y
        else:
            ds: uint256 = s * y / total_y
            assert ds > 0, "Amount too low"
            user_shares[i] = ds
            s += ds
        self.total_shares[band] = s
        # End the cycle
        band += 1
        if band > finish:
            break

    self.save_user_ticks(user, n1, n2, user_shares, save_n)


@external
def withdraw(user: address, move_to: address) -> uint256[2]:
    assert msg.sender == ADMIN

    ns: int256[2] = self._read_user_tick_numbers(user)
    user_shares: uint256[MAX_TICKS] = self._read_user_ticks(user, ns[1] - ns[0] + 1)
    assert user_shares[0] > 0, "No deposits"

    total_x: uint256 = 0
    total_y: uint256 = 0

    for i in range(MAX_TICKS):
        x: uint256 = self.bands_x[ns[0]]
        y: uint256 = self.bands_y[ns[0]]
        ds: uint256 = user_shares[i]
        s: uint256 = self.total_shares[ns[0]]
        dx: uint256 = x * ds / s
        dy: uint256 = y * ds / s

        self.total_shares[ns[0]] = s - ds
        self.bands_x[ns[0]] = x - dx
        self.bands_y[ns[0]] = y - dy
        total_x += dx
        total_y += dy

        ns[0] += 1
        if ns[0] > ns[1]:
            break

    self.empty_ticks(user)

    total_x /= BORROWED_PRECISION
    total_y /= COLLATERAL_PRECISION
    if move_to != ZERO_ADDRESS:
        assert ERC20(BORROWED_TOKEN).transfer(move_to, total_x)
        assert ERC20(COLLATERAL_TOKEN).transfer(move_to, total_y)

    return [total_x, total_y]


@internal
@view
def calc_swap_out(pump: bool, in_amount: uint256) -> DetailedTrade:
    out: DetailedTrade = empty(DetailedTrade)
    # pump = True: borrowable (USD) in, collateral (ETH) out; going up
    # pump = False: collateral (ETH) in, borrowable (USD) out; going down
    n: int256 = self.active_band
    out.n1 = n
    p_o: uint256 = self._price_oracle()
    p_o_up: uint256 = self._base_price() * self.p_base_mul / 10**18
    fee: uint256 = self.fee
    in_amount_left: uint256 = in_amount * (10**18 - fee) / 10**18
    in_amount_used: uint256 = 0
    fee = (10**18)**2 / (10**18 - fee)
    x: uint256 = self.bands_x[n]
    y: uint256 = self.bands_y[n]

    for i in range(MAX_TICKS):
        y0: uint256 = self._get_y0(x, y, p_o, p_o_up)
        f: uint256 = A * y0 * p_o / p_o_up * p_o / 10**18
        g: uint256 = (A - 1) * y0 * p_o_up / p_o
        Inv: uint256 = (f + x) * (g + y)

        if pump:
            if y > 0:
                x_dest: uint256 = Inv / g - f
                if x_dest - x >= in_amount_left:
                    # This is the last band
                    x += in_amount_left * fee / 10**18
                    out.last_tick_j = Inv / (f + x) - g  # Should be always >= 0
                    out.out_amount += y - out.last_tick_j
                    out.ticks_in[i] = x
                    out.n2 = n
                    out.in_amount = in_amount
                    return out

                else:
                    # We go into the next band
                    dx: uint256 = x_dest - x
                    in_amount_left -= dx
                    dx = dx * fee / 10**18
                    out.ticks_in[i] = x + dx
                    in_amount_used += dx
                    out.out_amount += y

            n += 1
            p_o_up = p_o_up * (A - 1) / A
            x = 0
            y = self.bands_y[n]

        else:  # dump
            if x > 0:
                y_dest: uint256 = Inv / f - g
                if y_dest - y >= in_amount_left:
                    # This is the last band
                    y += in_amount_left * fee / 10**18
                    out.last_tick_j = Inv / (g + y) - f
                    out.out_amount += x - out.last_tick_j
                    out.ticks_in[i] = y
                    out.n2 = n
                    out.in_amount = in_amount
                    return out

                else:
                    # We go into the next band
                    dy: uint256 = y_dest - y
                    in_amount_left -= dy
                    dy = dy * fee / 10**18
                    out.ticks_in[i] = y + dy
                    in_amount_used += dy
                    out.out_amount += x

            n -= 1
            p_o_up = p_o_up * A / (A - 1)
            x = self.bands_x[n]
            y = 0

    out.in_amount = in_amount_used
    return out


@external
@view
def get_dy(i: uint256, j: uint256, in_amount: uint256) -> uint256:
    assert (i == 0 and j == 1) or (i == 1 and j == 0), "Wrong index"
    precision: uint256 = 0
    precision_out: uint256 = 0
    if i == 0:
        precision = BORROWED_PRECISION
        precision_out = COLLATERAL_PRECISION
    else:
        precision = COLLATERAL_PRECISION
        precision_out = BORROWED_PRECISION
    out: DetailedTrade = self.calc_swap_out(i == 0, in_amount * precision)
    return out.out_amount / precision_out


# Can collapse in one function XXX
@external
@view
def get_dxdy(i: uint256, j: uint256, in_amount: uint256) -> (uint256, uint256):
    """
    Method to be used to figure if we have some in_amount left or not
    """
    assert (i == 0 and j == 1) or (i == 1 and j == 0), "Wrong index"
    precision: uint256 = 0
    precision_out: uint256 = 0
    if i == 0:
        precision = BORROWED_PRECISION
        precision_out = COLLATERAL_PRECISION
    else:
        precision = COLLATERAL_PRECISION
        precision_out = BORROWED_PRECISION
    out: DetailedTrade = self.calc_swap_out(i == 0, in_amount * precision)
    return (out.in_amount / precision, out.out_amount / precision_out)


@external
def exchange(i: uint256, j: uint256, in_amount: uint256, min_amount: uint256, _for: address = msg.sender) -> uint256:
    assert (i == 0 and j == 1) or (i == 1 and j == 0), "Wrong index"
    in_precision: uint256 = BORROWED_PRECISION
    out_precision: uint256 = COLLATERAL_PRECISION
    if i == 1:
        in_precision = COLLATERAL_PRECISION
        out_precision = BORROWED_PRECISION

    out: DetailedTrade = self.calc_swap_out(i == 0, in_amount * in_precision)
    assert out.out_amount / out_precision >= min_amount, "Slippage"

    in_coin: address = BORROWED_TOKEN
    out_coin: address = COLLATERAL_TOKEN
    if i == 1:
        in_coin = COLLATERAL_TOKEN
        out_coin = BORROWED_TOKEN

    ERC20(in_coin).transferFrom(msg.sender, self, out.in_amount)
    ERC20(out_coin).transfer(_for, out.out_amount / out_precision)

    n: int256 = out.n1
    step: int256 = 1
    if out.n2 < out.n1:
        step = -1
    for k in range(MAX_TICKS):
        if i == 0:
            self.bands_x[n] = out.ticks_in[k]
            if n == out.n2:
                self.bands_y[n] = out.last_tick_j
                break
            else:
                self.bands_y[n] = 0
        else:
            self.bands_y[n] = out.ticks_in[k]
            if n == out.n2:
                self.bands_x[n] = out.last_tick_j
                break
            else:
                self.bands_x[n] = 0
        n += step

    self.active_band = n
    p_base_mul: uint256 = self.p_base_mul
    n = abs(out.n2 - out.n1)
    for k in range(MAX_TICKS):
        if step == 1:
            p_base_mul = p_base_mul * (A - 1) / A
        else:
            p_base_mul = p_base_mul * A / (A - 1)
        if n == 0:
            break
        n -= 1
    self.p_base_mul = p_base_mul

    return out.out_amount / out_precision

# get_y_up(user) and get_x_down(user)
@external
@view
def get_y_up(user: address) -> uint256:
    """
    Measure the amount of y in the band n if we adiabatically trade near p_oracle on the way up
    """
    ns: int256[2] = self._read_user_tick_numbers(user)
    ticks: uint256[MAX_TICKS] = self._read_user_ticks(user, ns[1] - ns[0] + 1)
    if ticks[0] == 0:
        return 0
    p_o: uint256 = self._price_oracle()

    n: int256 = ns[0] - 1
    p_o_up: uint256 = self._p_oracle_band(n, False)
    Y: uint256 = 0

    for i in range(MAX_TICKS):
        n += 1
        if n > ns[1]:
            break
        p_o_up = p_o_up * (A - 1) / A
        total_share: uint256 = self.total_shares[n]
        user_share: uint256 = ticks[i]

        x: uint256 = self.bands_x[n]
        y: uint256 = self.bands_y[n]
        if x == 0:
            Y += y * user_share / total_share
            continue
        elif y == 0:
            Y += x * SQRT_BAND_RATIO / p_o_up * user_share / total_share
            continue

        y0: uint256 = self._get_y0(x, y, p_o, p_o_up)
        f: uint256 = A * y0 * p_o / p_o_up * p_o / 10**18
        g: uint256 = (A - 1) * y0 * p_o_up / p_o
        # (f + x)(g + y) = const = p_top * A**2 * y0**2 = I
        Inv: uint256 = (f + x) * (g + y)
        # p = (f + x) / (g + y) => p * (g + y)**2 = I or (f + x)**2 / p = I

        # First, "trade" in this band to p_oracle
        x_o: uint256 = 0
        y_o: uint256 = self.sqrt_int(Inv / p_o)
        if y_o < g:
            y_o = 0
        else:
            y_o -= g
        p_o_use: uint256 = p_o
        if y_o > 0:
            x_o = Inv / (g + y_o)
            if x_o < f:
                x_o = 0
                y_o = Inv / f - g
            else:
                x_o -= f
        else:
            x_o = Inv / g - f
            p_o_use = p_o_up * (A - 1) / A

        if x_o == 0:
            Y += y_o * user_share / total_share
        else:
            Y += (y_o + x_o / self.sqrt_int(p_o_up * p_o_use / 10**18)) * user_share / total_share

    return Y / COLLATERAL_PRECISION


@external
def set_rate(rate: int256):
    assert msg.sender == ADMIN
    self.base_price_0 = self._base_price()
    self.base_price_time = block.timestamp
    self.rate = rate


@external
def set_fee(fee: uint256):
    assert msg.sender == ADMIN
    assert fee < 10**18, "Fee is too high"
    self.fee = fee


# XXX total X
# XXX events
