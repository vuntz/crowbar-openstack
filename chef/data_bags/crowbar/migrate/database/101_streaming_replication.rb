def upgrade(ta, td, a, d)
  unless a["postgresql"].key?("streaming_replication")
    # don't convert anything existing to streaming replication
    a["postgresql"]["streaming_replication"] = false
  end
  return a, d
end

def downgrade(ta, td, a, d)
  unless ta["postgresql"].key?("streaming_replication")
    a["postgresql"].delete("streaming_replication")
  end
  return a, d
end
