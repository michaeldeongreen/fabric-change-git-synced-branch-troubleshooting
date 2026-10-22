# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {}
# META }

# MARKDOWN ********************

# # Populate Lakehouse_With_Data
#
# Run all cells to create `dbo.sample_orders` with 50 synthetic orders.
# The OneLake path uses `Workspace_ID` and `Lakehouse_With_Data_ID` from the
# `Variables` variable library; no default Lakehouse attachment is required.
#
# Rerunning replaces only this sample table, keeping the row count at 50.
# In the other Lakehouse, create a Tables shortcut to
# **Lakehouse_With_Data > Tables > dbo > sample_orders**.

# CELL ********************

import notebookutils

VARIABLE_LIBRARY_NAME = "Variables"

variable_library = notebookutils.variableLibrary.getLibrary(VARIABLE_LIBRARY_NAME)
target_workspace_id = variable_library.Workspace_ID
target_lakehouse_id = variable_library.Lakehouse_With_Data_ID
target_table_name = "sample_orders"

full_path = (
    f"abfss://{target_workspace_id}@onelake.dfs.fabric.microsoft.com/"
    f"{target_lakehouse_id}/Tables/dbo/{target_table_name}"
)

print(f"Variable library: {VARIABLE_LIBRARY_NAME}")
print(f"Target table: dbo.{target_table_name}")
print(f"OneLake path: {full_path}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

from datetime import date, timedelta
from decimal import Decimal

products = [
    ("Notebook", Decimal("4.50")),
    ("Pen", Decimal("1.25")),
    ("Mug", Decimal("9.00")),
    ("Backpack", Decimal("29.95")),
    ("Water Bottle", Decimal("14.50")),
]

rows = []
for order_id in range(1, 51):
    product, unit_price = products[(order_id - 1) % len(products)]
    quantity = (order_id - 1) % 4 + 1
    rows.append(
        (
            order_id,
            date(2026, 1, 1) + timedelta(days=order_id - 1),
            f"Customer {(order_id - 1) % 10 + 1:02d}",
            product,
            quantity,
            unit_price,
            (unit_price * quantity).quantize(Decimal("0.01")),
        )
    )

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

from pyspark.sql import SparkSession
from pyspark.sql.types import (
    DateType,
    DecimalType,
    IntegerType,
    StringType,
    StructField,
    StructType,
)

schema = StructType(
    [
        StructField("order_id", IntegerType(), False),
        StructField("order_date", DateType(), False),
        StructField("customer_name", StringType(), False),
        StructField("product", StringType(), False),
        StructField("quantity", IntegerType(), False),
        StructField("unit_price", DecimalType(10, 2), False),
        StructField("total_amount", DecimalType(12, 2), False),
    ]
)

spark = SparkSession.builder.getOrCreate()
orders_df = spark.createDataFrame(rows, schema)
orders_df.coalesce(1).write.format("delta").mode("overwrite").save(full_path)

written_df = spark.read.format("delta").load(full_path)
row_count = written_df.count()
if row_count != 50:
    raise RuntimeError(f"Expected 50 orders at {full_path}, found {row_count}.")

print(f"Verified {row_count} orders in dbo.{target_table_name}.")
written_df.orderBy("order_id").show(10, truncate=False)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
