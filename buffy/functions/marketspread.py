#!/usr/bin/env python3

"""
Market Trade Processor

Based on
https://docs.google.com/document/d/1qpxeWcWeUzymX6hOSWG_yuTunNd6J2UoyWLzTOQiiz4/

"""

from . import state


FUNC_NAME = 'Marketspread'


def func(input):
    # Deserialize input
    msg = parse_fix(input)
    if msg['type'] == 'nbbo':
        process_order(msg)
    elif msg['type'] == 'order':
        process_order(msg)
    elif msg['type'] in ('fill', 'heartbeat'):
        return None



def process_nbbo(msg):
    # Update market info in memory
    state.get_attribute('market', {})[msg['symbol']] = {
        'id': msg['id'],
        'last_msg_time': msg['time'],
        'symbol': msg['symbol'],
        'bid': msg['bid'],
        'offer': msg['offer'],
        'mid': (msg['bid'] + msg['offer'])/2,
        'stop_new_orders': ((msg['offer'] - msg['bid']) >= 0.05 and
                            (msg['offer'] - msg['bid']) >= 0.05)}
    return None


def process_order(msg):
    # Orders
    if msg['type'] == 'order':
        # Reject order if: order already exists, the symbol has
        # stop_new_orders set to True or ???
        if (msg['order'] in state.get_attribute('orders', {}) or
            state.get_attribute('market',
                                {})[msg['symbol']]['stop_new_orders']):
            return reject_order(msg)

        # otherwise, accept the order
        return accept_order(msg)


def reject_order(msg):
    pass


def accept_order(msg):
    pass


SOH = '\x01'
TAGS = {'0': ('message_id', str),
        '1': ('client_id', str),
        '11': ('order_id', str),
        '38': ('order_qty', float),
        '44': ('price', float),
        '54': ('side', int),
        '55': ('symbol', str),
        '60': ('message_time', str),
        '132': ('bid', float),
        '133': ('offer', float),}


def parse_fix(input):
    tuples = [part.split('=') for part in input.split(SOH)]
    output = {TAGS[tup[0]][0]: TAGS[tup[0]][1](tup[1]) for tup in tuples
              if tup[0] in TAGS}
    return output


# TESTS #
def test_parse_fix():
    input = ('8=FIX.4.2\x019=121\x0135=D\x011=CLIENT35\x0111=s0XCIa\x01'
             '21=3\x0138=4000\x0140=2\x0144=252.85366153511416\x0154=1\x01'
             '55=TSLA\x0160=20151204-14:30:00.000\x01107=Tesla Motors\x01'
             '10=108\x01')
    output = parse_fix(input)
    assert(0)
