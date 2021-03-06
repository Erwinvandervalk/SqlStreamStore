﻿namespace SqlStreamStore.Subscriptions
{
    using System;
    using System.Threading;
    using System.Threading.Tasks;
    using SqlStreamStore.Infrastructure;
    using SqlStreamStore;

    public abstract class SubscriptionBase : IDisposable
    {
        private int _pageSize = 50;
        private IDisposable _streamStoreAppendedSubscription;
        private readonly InterlockedBoolean _shouldFetch = new InterlockedBoolean();
        private readonly InterlockedBoolean _isFetching = new InterlockedBoolean();
        private readonly CancellationTokenSource _isDisposed = new CancellationTokenSource();

        protected SubscriptionBase(
            IReadonlyStreamStore readonlyStreamStore,
            IObservable<Unit> streamStoreAppendedNotification,
            StreamMessageReceived streamMessageReceived,
            SubscriptionDropped subscriptionDropped = null,
            string name = null)
        {
            ReadonlyStreamStore = readonlyStreamStore;
            StreamStoreAppendedNotification = streamStoreAppendedNotification;
            StreamMessageReceived = streamMessageReceived;
            Name = string.IsNullOrWhiteSpace(name) ? Guid.NewGuid().ToString() : name;
            SubscriptionDropped = subscriptionDropped ?? ((_, __) => { });
        }

        public string Name { get; }

        public int PageSize
        {
            get { return _pageSize; }
            set { _pageSize = (value <= 0) ? 1 : value; }
        }

        protected IObservable<Unit> StreamStoreAppendedNotification { get; }

        protected CancellationToken IsDisposed => _isDisposed.Token;

        protected IReadonlyStreamStore ReadonlyStreamStore { get; }

        protected StreamMessageReceived StreamMessageReceived { get; }

        protected SubscriptionDropped SubscriptionDropped { get; }

        public virtual Task Start(CancellationToken cancellationToken)
        {
            _streamStoreAppendedSubscription = StreamStoreAppendedNotification.Subscribe(_ =>
            {
                _shouldFetch.Set(true);
                Fetch();
            });
            Fetch();
            return Task.FromResult(0);
        }

        public void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }

        ~SubscriptionBase()
        {
            Dispose(false);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                _streamStoreAppendedSubscription?.Dispose();
                _isDisposed.Cancel();
            }
        }
        private void Fetch()
        {
            if (_isFetching.CompareExchange(true, false))
            {
                return;
            }
            Task.Run(async () =>
            {
                try
                {
                    bool isEnd = false;
                    while(_shouldFetch.CompareExchange(false, true) || !isEnd)
                    {
                        isEnd = await DoFetch();
                    }
                }
                catch(Exception ex)
                {
                    // Drop subscription
                }
                finally
                {
                    _isFetching.Set(false);
                }
            }, IsDisposed);
        }

        protected abstract Task<bool> DoFetch();
    }
}
