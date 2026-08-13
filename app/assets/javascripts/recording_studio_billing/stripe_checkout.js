(() => {
  const mount = document.querySelector("[data-stripe-checkout-client-secret]");
  if (!mount || !window.Stripe) return;

  // The server supplies only a provider-created client secret. Card data is
  // submitted directly to Stripe and browser completion never fulfils an intent.
  const stripe = window.Stripe(mount.dataset.stripePublishableKey);
  stripe.initEmbeddedCheckout({ clientSecret: mount.dataset.stripeCheckoutClientSecret })
    .then((checkout) => checkout.mount(mount));
})();