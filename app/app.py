"""Olist bad-review risk scorer.

Enter an order's delivery details and see how likely the customer is to leave a 1-2 star review,
compared with the average order. The model is the gradient-boosting classifier trained in
olist_lead_to_loyal.ipynb (2016-2017 orders for training, 2018 orders for testing, AUC 0.77).

Run locally:  pip install -r requirements.txt  then  streamlit run app.py
"""
import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import streamlit as st

HERE = Path(__file__).parent
st.set_page_config(page_title="Olist bad-review risk", layout="wide")


@st.cache_resource
def load():
    bundle = joblib.load(HERE / "bad_review_model.joblib")
    names = json.loads((HERE / "categories_en.json").read_text())
    return bundle, names


bundle, cat_en = load()
model, numeric, categorical = bundle["model"], bundle["numeric"], bundle["categorical"]
defaults, cats = bundle["defaults"], bundle["categories"]
base_rate, pcts = bundle["base_rate"], np.array(bundle["risk_percentiles"])

PRESETS = {
    "Smooth single-item order": dict(days_vs_promise=-12, delivery_days=10, days_to_ship=2, n_items=1, n_sellers=1, seller_late=1),
    "Delivered 6 days late": dict(days_vs_promise=6, delivery_days=30, days_to_ship=5, n_items=1, n_sellers=1, seller_late=10),
    "Split shipment (2 sellers, on time)": dict(days_vs_promise=-10, delivery_days=12, days_to_ship=2, n_items=2, n_sellers=2, seller_late=2),
}


def predict(row: dict) -> float:
    df = pd.DataFrame([row])[numeric + categorical]
    for c in categorical:
        df[c] = pd.Categorical(df[c], categories=cats[c])
    return float(model.predict_proba(df)[0, 1])


st.title("Will this customer leave a 1–2★ review?")
st.caption("A gradient-boosting model trained on ~43,000 Olist orders (2016–2017) and tested on ~52,000 orders from 2018 "
           f"(AUC {bundle['auc']:.2f}). It scores an order at the moment of delivery, so a CRM team can reach unhappy "
           "customers before the review survey goes out.")

preset = st.radio("Start from an example", list(PRESETS), horizontal=True)
p = PRESETS[preset]

left, right = st.columns([1, 1], gap="large")
with left:
    st.subheader("Delivery")
    days_vs_promise = st.slider("Days late (negative = early)", -30, 30, p["days_vs_promise"],
                                help="Delivery date minus the date promised at checkout")
    delivery_days = st.slider("Days from purchase to delivery", 1, 60, p["delivery_days"])
    days_to_ship = st.slider("Days the seller took to hand over the package", 0, 20, p["days_to_ship"])
    st.subheader("Order")
    c1, c2 = st.columns(2)
    n_items = c1.number_input("Items in the order", 1, 10, p["n_items"])
    n_sellers = c2.number_input("Different sellers", 1, 5, min(p["n_sellers"], p["n_items"]))
    c3, c4 = st.columns(2)
    price = c3.number_input("Total price (R$)", 1.0, 5000.0, float(defaults["price"]), step=10.0)
    freight = c4.number_input("Shipping cost (R$)", 0.0, 500.0, float(defaults["freight"]), step=1.0)
    category = st.selectbox("Product category", cats["category"],
                            index=cats["category"].index(defaults["category"]),
                            format_func=lambda c: cat_en.get(c, c).replace("_", " "))
    st.subheader("Where and who")
    c5, c6 = st.columns(2)
    customer_state = c5.selectbox("Customer state", cats["customer_state"], index=cats["customer_state"].index("SP"))
    seller_state = c6.selectbox("Seller state", cats["seller_state"], index=cats["seller_state"].index("SP"))
    seller_late = st.slider("Seller's past late-delivery rate (%)", 0, 50, p["seller_late"])

row = {**defaults,
       "days_vs_promise": days_vs_promise, "delivery_days": delivery_days, "days_to_ship": days_to_ship,
       "promised_days": delivery_days - days_vs_promise, "n_items": n_items, "n_sellers": n_sellers,
       "price": price, "freight": freight, "freight_share": freight / price, "category": category,
       "customer_state": customer_state, "seller_state": seller_state,
       "same_state": int(customer_state == seller_state), "seller_prior_late_rate": seller_late / 100}
risk = predict(row)
riskier_than = int(np.searchsorted(pcts, risk))

with right:
    st.subheader("Result")
    m1, m2 = st.columns(2)
    m1.metric("Chance of a 1–2★ review", f"{risk:.0%}", f"{(risk - base_rate) * 100:+.0f} pts vs average", delta_color="inverse")
    m2.metric("Riskier than this share of 2018 orders", f"{min(riskier_than, 99)}%")
    if riskier_than >= 90:
        st.error("In the riskiest 10%: send to the service-recovery flow (apology, tracking help, voucher) before the survey.")
    elif riskier_than >= 75:
        st.warning("Above-average risk: worth a proactive tracking update.")
    else:
        st.success("Low risk: no action needed.")

    st.subheader("What moves this score")
    st.caption("Each bar shows how much the risk changes if that one detail were typical instead (all else unchanged).")
    typical = {"Days late": {"days_vs_promise": defaults["days_vs_promise"],
                             "promised_days": delivery_days - defaults["days_vs_promise"]},
               "Delivery time": {"delivery_days": defaults["delivery_days"],
                                 "promised_days": defaults["delivery_days"] - days_vs_promise},
               "Seller handover time": {"days_to_ship": defaults["days_to_ship"]},
               "Number of items": {"n_items": 1, "n_sellers": 1},
               "Price and shipping": {"price": defaults["price"], "freight": defaults["freight"],
                                      "freight_share": defaults["freight_share"]},
               "Product category": {"category": defaults["category"]},
               "Seller's track record": {"seller_prior_late_rate": defaults["seller_prior_late_rate"]}}
    effects = {k: (risk - predict({**row, **v})) * 100 for k, v in typical.items()}
    eff = pd.Series(effects).sort_values(key=abs, ascending=False).head(5)
    st.bar_chart(eff.rename("Change in risk (points)"), horizontal=True, color="#eb6834")
    top = eff.index[0]
    if abs(eff.iloc[0]) >= 2:
        st.write(f"**Biggest driver: {top.lower()}** ({eff.iloc[0]:+.0f} points compared with a typical order).")
    else:
        st.write("Nothing unusual about this order: it looks like a typical delivery.")

st.divider()
st.caption("Built by Amelie Pham · Data: Brazilian E-Commerce Public Dataset by Olist (Kaggle) · "
           "Model and full analysis in the project notebook. The score is a probability estimate, not a certainty.")
