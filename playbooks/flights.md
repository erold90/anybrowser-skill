# Flights: the exact price, with bags, and offers

Verified on 12/09/2026 in Safari, in Italian, on Google Voli and ryanair.com, for
Brindisi → Milano on 15/10/2026. easyJet, Wizz Air, ITA and Skyscanner are not verified yet.

## Why the browser

A flight's price is made by the site's scripts when you search, changes by the hour, and
its bag fees only appear inside the booking steps. A web search or a page fetched without
scripts gives old or indicative prices. The browser shows what a traveller sees now.

## The method

1. **Ask what changes the price:**
   - from and to (an airport or a city: MIL is every Milan airport);
   - dates, and one way or return;
   - passengers (adults, children, infants);
   - bags: a small one under the seat, a 10 kg cabin bag, a 20 kg hold bag.
2. **Overview on Google Voli**, in a window of your own. Its `q=` takes plain words:
   ```
   tab new "https://www.google.com/travel/flights?q=voli%20da%20BDS%20a%20MIL%20il%202026-10-15%20solo%20andata&curr=EUR&hl=it&gl=it" --window
   waitgone "Caricamento dei risultati" 20
   text
   ```
   Each flight reads as departure, arrival, airline, route, stops, then price.
3. **The exact price on the airline's own site.** The comparator rounds, and it estimates the bags.
4. **Stop before anything personal**: passenger names, signing in, payment. Report:
   - the price and what it includes;
   - when you read it;
   - the link.

## Google Voli

- Prices are for one adult, taxes included, rounded to the euro (20 € for 19,99 €).
- `click Bagagli` opens a panel with **cabin bags only** (`Aggiungi bagaglio a mano`); there is no
  hold-bag filter. Adding a bag closes the panel and reloads the results, with the cabin-bag fee added.
- That fee is Google's estimate, and it can be wrong:
  - For Ryanair FR 3449 it gave 56 €, but the airline's Regular fare with a 10 kg cabin bag cost 49,43 €.
  - An easyJet flight stayed at 16 €, as if its free under-seat bag counted as the cabin bag.
- A note under the results says when prices are low or high for that search.

## Ryanair

- **Straight to the fares**, with no form to fill (for a return: `isReturn=true&dateIn=YYYY-MM-DD`):
  `https://www.ryanair.com/it/it/trip/flights/select?adults=1&teens=0&children=0&infants=0&dateOut=2026-10-15&dateIn=&isConnectedFlight=false&discount=0&isReturn=false&promoCode=&originIata=BDS&destinationIata=BGY&tpAdults=1&tpTeens=0&tpChildren=0&tpInfants=0&tpStartDate=2026-10-15&tpEndDate=&tpDiscount=0&tpPromoCode=&tpOriginIata=BDS&tpDestinationIata=BGY`
- **Cookie banner:** `Visualizza impostazioni cookie` · `No, grazie` · `Sì, accetto`. Refuse with `click "No, grazie"`.
- **The list of flights:**
  - A strip of five days shows each day's lowest fare.
  - Each flight has its number, its times and its **Tariffa Basic**.
  - **An offer shows two prices**, the old one first (`26,14 €` then `23,66 €`).
- **Fares:** `find button Seleziona` numbers the flights in the order listed, and `click @4` opens
  that flight's fares. The `+` prices are per passenger and per flight, on top of Basic (FR 3449):

  | Fare | What it adds | Price |
  |---|---|---|
  | Basic | a small bag under the seat | 19,99 € |
  | Regular | seat, priority boarding, 10 kg cabin bag | + 29,44 € |
  | Plus | seat and a **20 kg hold bag**, the only fare that includes one | + 38,24 € |
  | Flexi Plus | changes without fees | + 98,44 € |

- **After the fares** come Posti → Bagagli → Extra → Revisione e pagamento.
  - The price of a hold bag added to Basic only shows at **Bagagli**, which comes after the
    passengers' names. Stop there and ask the user.
  - Plus already gives an exact price with 20 kg included.
- In Safari a price is laid out in pieces (`€`, `19`, `,`, `99`); `text` joins them back into `€ 19,99`.

## Airport codes met

BDS Brindisi · BRI Bari · BGY Milano Bergamo · MXP Milano Malpensa · LIN Milano Linate · MIL all of Milan.
