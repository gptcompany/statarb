import asyncio
from redis import asyncio as aioredis
from datetime import datetime, timezone
from statistics import mean
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

async def check_redis_updates(redis_host, redis_port, use_ssl=True, trade_threshold=10, threshold_seconds=0.2, num_updates=5, check_interval=2, symbols=['BTC-USDT']):
    """
    Continuously checks Redis for the last update and calculates the mean time interval between updates for books.
    For trades, it checks if the last timestamp is over 10 seconds.
    Logs warnings or errors based on update timings.
    """
    while True:
        try:
            # Connect to Redis
            url = f"rediss://{redis_host}:{redis_port}" if use_ssl else f"redis://{redis_host}:{redis_port}"
            r = await aioredis.from_url(url, decode_responses=True)

            for symbol in symbols:
                # Check book updates
                book_key = f"book-BINANCE-{symbol}"
                book_updates = await r.zrange(book_key, -num_updates, -1, withscores=True)
                await process_book_updates(book_updates, symbol, threshold_seconds, num_updates)

                # Check trade updates
                trade_key = f"trades-BINANCE-{symbol}"
                trade_update = await r.zrange(trade_key, -1, -1, withscores=True)
                await process_trade_update(trade_update, symbol, trade_threshold)

        except Exception as e:
            logger.error(f"Error occurred: {e}")
        finally:
            # Close the Redis connection
            await r.aclose()

        # Wait before checking again
        await asyncio.sleep(check_interval)

async def process_book_updates(book_updates, symbol, threshold_seconds, num_updates):
    if len(book_updates) < num_updates:
        logger.warning(f"Insufficient data for mean interval calculation for book {symbol}.")
    else:
        timestamps = [float(score) for _, score in book_updates]
        current_time = datetime.now(timezone.utc).timestamp()
        timestamps.append(current_time)
        time_diffs = [timestamps[i] - timestamps[i - 1] for i in range(1, len(timestamps))]
        mean_diff = mean(time_diffs)
        if mean_diff > threshold_seconds:
            logger.warning(f"Mean interval ({mean_diff} seconds) for book {symbol} is above threshold. Last updates at {[datetime.fromtimestamp(ts, tz=timezone.utc).isoformat() for ts in timestamps[:-1]]}")
        else:
            logger.info(f"Mean update interval for book {symbol} is {mean_diff} seconds")

async def process_trade_update(trade_update, symbol, trade_threshold=10):
    if not trade_update:
        logger.warning(f"No trade data found for {symbol}.")
    else:
        _, last_timestamp = trade_update[0]
        last_update_time = datetime.fromtimestamp(last_timestamp, tz=timezone.utc)
        current_time = datetime.now(timezone.utc)
        time_diff = (current_time - last_update_time).total_seconds()
        if time_diff > trade_threshold:
            logger.warning(f"Last trade update for {symbol} is more than {trade_threshold} seconds old. Last update was at {last_update_time.isoformat()}")
        else:
            logger.info(f"Last update interval for {symbol} is at {last_update_time} , data is {time_diff} seconds ago.")
            
            
if __name__ == '__main__':
    redis_host="redis-0001-001.redis.tetmd7.apne1.cache.amazonaws.com"
    redis_port=6379
    asyncio.run(asyncio.run(check_redis_updates(redis_host=redis_host, 
                                                redis_port=redis_port, 
                                                use_ssl=True,
                                                trade_threshold=10,
                                                threshold_seconds=0.2, 
                                                num_updates=5, 
                                                check_interval=2, 
                                                symbols=['BTC-USDT'],
                                                )
                            )
                )

