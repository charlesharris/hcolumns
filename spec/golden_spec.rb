# frozen_string_literal: true

RSpec.describe "golden column render" do
  it "renders the src/orders.rb column as expected" do
    now = FIXED_NOW
    graph = HColumns::Providers::InMemoryFixture.build(now: now)
    column = HColumns::ColumnBuilder.new(graph).build(
      HColumns::Providers::InMemoryFixture.orders_id, now: now
    )
    golden("orders_column.txt", HColumns::Renderers::Text.new.render(column))
  end
end
