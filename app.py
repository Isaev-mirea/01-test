"""Учебный магазин: Flask, SQLite, серверная HTML-разметка."""
import json
import os
import secrets
import sqlite3
from pathlib import Path

from flask import Flask, abort, flash, g, redirect, render_template, request, session, url_for

BASE_DIR = Path(__file__).resolve().parent


def get_db():
    if "db" not in g:
        from flask import current_app
        g.db = sqlite3.connect(current_app.config["DATABASE"])
        g.db.row_factory = sqlite3.Row
    return g.db


def create_app(test_config=None):
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=os.environ.get("SHOP_SECRET_KEY") or secrets.token_hex(32),
        DATABASE=os.environ.get("SHOP_DATABASE", str(BASE_DIR / "instance" / "shop.db")),
        VERSION=os.environ.get("BUILD_VERSION", "1.0.0"),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        MAX_CONTENT_LENGTH=16 * 1024,
    )
    if test_config:
        app.config.update(test_config)
    Path(app.config["DATABASE"]).parent.mkdir(parents=True, exist_ok=True)

    @app.teardown_appcontext
    def close_db(error=None):
        db = g.pop("db", None)
        if db is not None:
            db.close()

    with app.app_context():
        db = get_db()
        # Seed only a new database; an intentionally empty catalog stays empty.
        exists = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='products'").fetchone()
        db.execute("CREATE TABLE IF NOT EXISTS products (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price_cents INTEGER NOT NULL CHECK(price_cents > 0))")
        if not exists:
            products = json.loads((BASE_DIR / "data" / "products.json").read_text(encoding="utf-8"))
            db.executemany("INSERT INTO products (id, name, price_cents) VALUES (:id, :name, :price_cents)", products)
        db.commit()

    @app.template_filter("money")
    def money(cents):
        return f"{cents // 100:,}".replace(",", " ") + f",{cents % 100:02d} ₽"

    @app.context_processor
    def common():
        if "csrf" not in session:
            session["csrf"] = secrets.token_hex(24)
        return dict(csrf_token=session["csrf"], cart_count=sum(session.get("cart", {}).values()), version=app.config["VERSION"])

    @app.before_request
    def check_csrf():
        if request.method == "POST":
            expected = session.get("csrf", "")
            supplied = request.form.get("csrf_token", "")
            if not expected or not secrets.compare_digest(expected, supplied):
                abort(400, "Invalid form token. Reload the page and try again.")

    @app.get("/")
    def catalog():
        return render_template("catalog.html", products=get_db().execute("SELECT * FROM products ORDER BY id").fetchall())

    @app.post("/cart/add/<int:product_id>")
    def add_to_cart(product_id):
        product = get_db().execute("SELECT * FROM products WHERE id = ?", (product_id,)).fetchone()
        if product is None:
            abort(404)
        cart = dict(session.get("cart", {}))
        key = str(product_id)
        cart[key] = cart.get(key, 0) + 1
        session["cart"] = cart
        flash(f"Товар «{product['name']}» добавлен в корзину.")
        return redirect(url_for("catalog"), code=303)

    @app.get("/cart")
    def cart():
        quantities = session.get("cart", {})
        items = []
        for product in get_db().execute("SELECT * FROM products ORDER BY id"):
            quantity = quantities.get(str(product["id"]), 0)
            if quantity:
                items.append(dict(product, quantity=quantity, subtotal=quantity * product["price_cents"]))
        return render_template("cart.html", items=items, total=sum(item["subtotal"] for item in items))

    @app.post("/cart/clear")
    def clear_cart():
        session.pop("cart", None)
        flash("Корзина очищена.")
        return redirect(url_for("cart"), code=303)

    @app.get("/health")
    def health():
        get_db().execute("SELECT 1").fetchone()
        return {"status": "ok", "version": app.config["VERSION"]}

    return app


if __name__ == "__main__":
    from waitress import serve
    serve(create_app(), host="127.0.0.1", port=int(os.environ.get("PORT", "8000")))
