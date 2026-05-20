BEGIN
  -- Loop over old GA shards and drop each one individually
  FOR t IN (
    SELECT table_name
    FROM `commcare-a57e4.analytics_153906101.INFORMATION_SCHEMA.TABLES`
    WHERE REGEXP_CONTAINS(table_name, r'^events(_intraday)?_[0-9]{8}$')
      AND PARSE_DATE('%Y%m%d', REGEXP_EXTRACT(table_name, r'([0-9]{8})'))
          < DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
  )
  DO
    EXECUTE IMMEDIATE FORMAT(
      "DROP TABLE `commcare-a57e4.analytics_153906101.%s`;",
      t.table_name
    );
  END FOR;
END;