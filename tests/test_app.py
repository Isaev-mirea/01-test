from contextlib import closing
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from app import BASE_DIR, create_app


class ShopTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self.tmp.name) / "shop.db"
        self.app = create_app({"TESTING": True, "SECRET_KEY": "only-for-tests", "DATABASE": str(self.db_path)})
        self.client = self.app.test_client()
        self.client.get("/")

    def tearDown(self):
        self.tmp.cleanup()

    def post(self, path, client=None):
        client = client or self.client
        with client.session_transaction() as session:
            token = session["csrf"]
        return client.post(path, data={"csrf_token": token}, follow_redirects=True)

    def test_catalog_has_five_products(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.text.count('class="card"'), 5)
        self.assertIn("Масляный фильтр", response.text)
        self.assertIn("650,00 ₽", response.text)

    def test_product_dataset_is_valid(self):
        rows = json.loads((BASE_DIR / "data/products.json").read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(rows), 5)
        self.assertEqual(len({row["id"] for row in rows}), len(rows))
        for row in rows:
            self.assertTrue(row["name"].strip())
            self.assertIs(type(row["price_cents"]), int)
            self.assertGreater(row["price_cents"], 0)
        self.assertEqual(json.loads((BASE_DIR / "data/empty-products.json").read_text()), [])

    def test_empty_catalog(self):
        with closing(sqlite3.connect(self.db_path)) as db, db:
            db.execute("DELETE FROM products")
        self.assertIn("Товары не найдены", self.client.get("/").text)

    def test_empty_cart(self):
        self.assertIn("Корзина пуста", self.client.get("/cart").text)

    def test_first_add_and_confirmation(self):
        response = self.post("/cart/add/1")
        self.assertIn("добавлен в корзину", response.text)
        with self.client.session_transaction() as session:
            self.assertEqual(session["cart"], {"1": 1})

    def test_repeated_add_increases_quantity(self):
        self.post("/cart/add/1")
        self.post("/cart/add/1")
        with self.client.session_transaction() as session:
            self.assertEqual(session["cart"], {"1": 2})

    def test_multiple_products_and_total(self):
        self.post("/cart/add/1")
        self.post("/cart/add/1")
        self.post("/cart/add/2")
        text = self.client.get("/cart").text
        self.assertIn("1 300,00 ₽", text)
        self.assertIn("2 190,00 ₽", text)
        with self.client.session_transaction() as session:
            self.assertEqual(session["cart"], {"1": 2, "2": 1})

    def test_control_example_450_rubles(self):
        with closing(sqlite3.connect(self.db_path)) as db, db:
            db.execute("UPDATE products SET price_cents=10000 WHERE id=1")
            db.execute("UPDATE products SET price_cents=25000 WHERE id=2")
        self.post("/cart/add/1")
        self.post("/cart/add/1")
        self.post("/cart/add/2")
        self.assertIn("<strong>450,00 ₽</strong>", self.client.get("/cart").text)

    def test_fractional_price_uses_integer_arithmetic(self):
        self.post("/cart/add/5")
        self.post("/cart/add/5")
        self.post("/cart/add/5")
        self.assertIn("<strong>3 751,50 ₽</strong>", self.client.get("/cart").text)

    def test_unknown_product_is_404(self):
        self.assertEqual(self.post("/cart/add/999").status_code, 404)
        with self.client.session_transaction() as session:
            self.assertNotIn("cart", session)

    def test_csrf_is_required(self):
        self.assertEqual(self.client.post("/cart/add/1").status_code, 400)

    def test_separate_visitors_have_separate_carts(self):
        self.post("/cart/add/1")
        other = self.app.test_client()
        self.assertIn("Корзина пуста", other.get("/cart").text)

    def test_clear_cart(self):
        self.post("/cart/add/1")
        self.assertIn("Корзина пуста", self.post("/cart/clear").text)

    def test_database_is_not_reseeded_on_restart(self):
        with closing(sqlite3.connect(self.db_path)) as db, db:
            db.execute("DELETE FROM products")
        other_app = create_app({"TESTING": True, "SECRET_KEY": "only-for-tests", "DATABASE": str(self.db_path)})
        self.assertIn("Товары не найдены", other_app.test_client().get("/").text)

    def test_health(self):
        self.assertEqual(self.client.get("/health").json, {"status": "ok", "version": "1.0.0"})


if __name__ == "__main__":
    unittest.main()
