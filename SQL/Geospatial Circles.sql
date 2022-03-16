
/*
This script creates three circle objects of varying size in the Snowflake cloud data platform. 

The challenge of traversing the sphere of the Earth using bearing was resolved using
formulae from Movable Type Scripts - https://www.movable-type.co.uk/scripts/latlong.html

This allows us to maintain accurate distancing, even if the drawn polygons do not look like circles on a Mercator projection.

The code generates 120 points for each circle, using spherical trigonometry to calculate the location for each coordinate.
*/

create or replace transient database geographic_data_testing;

create or replace transient schema geographic_data_testing.geospatial_circles;

use geographic_data_testing.geospatial_circles;

-- Create a table with the different longitude and latitude locations of each data point 
create or replace transient table locations (
    id number identity
  , latitude float
  , longitude float
  , operational_range float
)
as
select *
from values 
    (1, 51.5072, -0.1276, 900000)
  , (2, 40.4832, -96.4044, 2400000)
  , (3, 28.3636, 77.1348, 5000000)
  , (4, -18.1, 178.27, 200000)
  , (5, 67.017, -178.242, 450000)
;

-- Use a table generator to create a simple table of row IDs.
-- The circles we generate will actually be straight-edged shapes with 
-- many points on the boundary, giving the appearance of a circle. 
-- This table generates the rows required for the number of points on the circle boundary.
create or replace view generated_rows 
as
select
  ROW_NUMBER() OVER (ORDER BY 1) - 1 as generated_row_id
from table(generator(rowcount => 200))
;

-- This is the most complex step, where we generate the
-- points that form the boundary of each circle. This is achieved
-- mathematically, by traversing around our circle in small increments
-- and noting the coordinates of each point along the way.

-- Once we have generated these sets of circle points and stored these
-- in a view (or CTE if you prefer), then we can create the full
-- polygon in a later view. 

-- An additional challenge here is that Snowflake's understanding of spatial 
-- data is based on geographical longitude and latitude instead of a standard 
-- two-dimensional coordinate system, which complicates our mathematics in 3 ways:

--  1.  We must consider the curvature of the Earth. Instead of simply drawing
--      a circle on a plane, we are drawing it on the surface of a sphere.
--      This is our main challenge.

--  2.  When drawing circles that cross the antimeridian of the Earth, we must take into 
--      account how the longitude/latitude will adjust as we traverse to the 
--      opposite end of the scale. The longitude must always be 
--      between -180 and 180, so if we exceed this range during our calculations 
--      then we must adjust by 360 to return to this range. This is achieved by 
--      leveraging a MODULO function

--  3.  When drawing circles that cross the antimeridian of the Earth, we must
--      consider how these objects will be respresented in Snowflake's geoJSON
--      structure and how these will be rendered on display software

-- Taking the above into account, we follow these steps to calculate the points on each circle:

--  1.  Define our standard input variables
--      -   Radius of Earth, in the same units of measurement as the
--          operational range that we are using as the radius of our circle
--      -   Total number of points we wish to use when approximating our circle,
--          where a higher value takes longer to compute but yields
--          greater accuracy

--  2.  Retrieve the data for our locations
--      -   Location ID
--      -   Location latitude
--      -   Location longtitude
--      -   Circle radius, in the same units of measurement as the
--          radius of the Earth, which we retrieve as the operational
--          range of our location

--  3.  Calculate values based on the input data for a location
--      -   Angular distance, which is the angle between the center of the
--          circle and its boundary, from the perspective of the center
--          of the sphere (i.e. Earth) 
--      -   Location longitude in radians, converted from degrees
--      -   Location latitude in radians, converted from degrees

--  4.  Retrieve input data for the specific point being identified
--      -   Circle Point ID

--  5.  Calculate the bearing for the point from the central location
--      -   Circle point bearing in degrees, which is the angle 
--          between the center location and the circle point,
--          from the perspective of the meridian
--      -   Circle point bearing in radians, converted from degrees

--  6.  Calculate the latitude and longitude of the point on the circle
--      -   Circle point latitude in radians, calculated with the
--          most complex formula in this process
--      -   Circle point latitude, converted from radians to degrees
--      -   Raw circle point longitude in radians, calculated with the
--          most complex formula in this process before adjusting to the boundary
--      -   Circle point longitude in radians, which is the raw value above
--          after an adjustment to remain within the boundary of -π to π
--      -   Circle point longitude, converted from radians to degrees

--  7.  Generate the specific point on the circle
--      -   Circle point

create or replace view circle_points 
as   
select 
  --  1.  Define our standard input variables
    6371009 as radius_of_earth
  , 120 as total_points_in_circle

  --  2.  Retrieve the data for our locations
  , locations.id as location_id
  , locations.longitude as location_longitude
  , locations.latitude as location_latitude
  , locations.operational_range as circle_radius

  --  3.  Calculate values based on the input data for a location
  , circle_radius / radius_of_earth as angular_distance
  , RADIANS(location_longitude) as location_longitude_radians
  , RADIANS(location_latitude) as location_latitude_radians

  --  4.  Retrieve input data for the specific point being identified
  , generated_row_id as circle_point_id

  --  5.  Calculate the bearing for the point from the central location
  , MOD(360 * circle_point_id / total_points_in_circle, 360) as circle_point_bearing_degrees
  , RADIANS(circle_point_bearing_degrees) as circle_point_bearing_radians

  --  6.  Calculate the latitude and longitude of the point on the circle
  , ASIN(SIN(location_latitude_radians)*COS(angular_distance) 
      + COS(location_latitude_radians)*SIN(angular_distance)*COS(circle_point_bearing_radians) )
      as circle_point_latitude_radians 
  , DEGREES(circle_point_latitude_radians) as circle_point_latitude

  , location_longitude_radians 
      + ATAN2(
            SIN(circle_point_bearing_radians) * SIN(angular_distance) * COS(location_latitude_radians)
          , COS(angular_distance) - SIN(location_latitude_radians) * SIN(circle_point_latitude_radians)
    ) as circle_point_longitude_radians
  , DEGREES(MOD(circle_point_longitude_radians + 3*PI(), 2*PI()) - PI()) as circle_point_longitude

  --  7.  Generate the specific point on the circle
  , ST_MAKEPOINT(circle_point_longitude, circle_point_latitude) as circle_point

from locations
  cross join generated_rows
where generated_row_id <= total_points_in_circle -- Use <= as we want to finish at the same point we started to ensure antimeridian crossing check is fully scoped
order by 
    location_id
  , circle_point_id
;

-----------------------------------------------------------------------------------
-- OPTION 1: IGNORE ANTIMERIDIAN CROSSING ISSUE
-----------------------------------------------------------------------------------

-- Use ST_COLLECT to group the points for each circle together.
-- This should act on the points as they are ordered in the input,
-- and thus create a collection of ordered points
-- around the boundary of our circle
create or replace view circle_points_collected
as
select 
    location_id
  , ST_COLLECT(circle_point) as collected_points
from circle_points
group by
    location_id
;

-- Finally, convert the collected points into polygons.
-- We make a line between our collected points and the starting point
-- for the circle (since the circle must start and end at the same location).
-- This is achieved with ST_MAKELINE()

-- We can then make a full circular polygon out of this line with ST_MAKEPOLYGON().
-- The filter for circle_point_id = 0 ensures that the join back to 
-- circle_points only picks up the starting point for the circle.
create or replace view circle_objects
as
select 
    points.location_id
  , ST_MAKEPOLYGON(
      ST_MAKELINE(
        collected_points
      , circle_point
      ) 
    ) as circle_poly
from circle_points as points
  inner join circle_points_collected as collected
    on points.location_id = collected.location_id
where circle_point_id = 0
;

select * from circle_objects;

-----------------------------------------------------------------------------------
-- OPTION 2: ATTEMPT TO SOLVE ANTIMERIDIAN CROSSING ISSUE
-----------------------------------------------------------------------------------

--  When rendering a GeoJSON structure, it is critical to add specific points when
--  crossing the antimeridian, where East becomes West and 180° becomes -180°.
--  We create another view to contain these additional points.

--  1.  Retrieve the data for our locations and circle points
--      -   Location ID
--      -   Circle point ID, which is between the two points whose
--          line crosses the antimeridian
--      -   Circle point latitude
--      -   Circle point longtitude
--      -   Previous point latitude
--      -   Previous point longtitude

--  2.  Test for crossing the antimeridian
--      -   Crosses antimeridian flag

--  3.  Calculate values based on the input data
--      -   Antimeridian crossing direction modifier, which is 
--          -1 when crossing from West to East and 
--          1 when crossing from East to West
--      -   Gradient of the line, which is considered after shifting
--          the coordinates to a range of 0° to 360° using a MODULO
--          function
--      -   Intercept, leveraging the standard formula for a straight
--          line where y = mx + c, where x and y are the longitude
--          and latitude of the circle point
--      -   Antimeridian crossing longitude
--      -   Antimeridian crossing latitude

--  4.  Generate the specific point on the circle
--      -   Circle point

create or replace view antimeridian_crossings
as
select
  --  1.  Retrieve the data for our locations and circle points
    location_id
  , circle_point_id - 0.5 as circle_point_id
  , circle_point_latitude
  , circle_point_longitude
  , lag(circle_point_latitude, 1) over (partition by location_id order by circle_point_id) as previous_latitude
  , lag(circle_point_longitude, 1) over (partition by location_id order by circle_point_id) as previous_longitude
  
  --  2.  Test for crossing the antimeridian
  , ABS(circle_point_longitude - previous_longitude) > 180 as crosses_antimeridian_flag
  
  --  3.  Calculate values based on the input data
  , IFF(circle_point_longitude < previous_longitude, -1, 1) as antimeridian_crossing_direction_modifier
  , (circle_point_latitude - previous_latitude) / (MOD(360 + circle_point_longitude, 360) - MOD(360 + previous_longitude, 360)) as gradient 
  , circle_point_latitude - gradient * circle_point_longitude as intercept
  , antimeridian_crossing_direction_modifier * 180 as antimeridian_crossing_longitude
  , gradient * antimeridian_crossing_longitude * 180 + intercept as antimeridian_crossing_latitude

  --  4.  Generate the specific point on the circle
  , ST_MAKEPOINT(antimeridian_crossing_longitude, antimeridian_crossing_latitude) as circle_point
  
from circle_points
qualify crosses_antimeridian_flag
;

-- Add the antimeridian crossings to our main set of points
create or replace view circle_points_with_antimeridian_crossings
as
  select
      location_id
    , circle_point_id
    , circle_point
  from circle_points
  where circle_point_id < total_points_in_circle
union all
  select
      location_id
    , circle_point_id - 0.1
    , ST_MAKEPOINT(antimeridian_crossing_longitude, antimeridian_crossing_latitude) as circle_point
  from antimeridian_crossings
union all
  select
      location_id
    , circle_point_id + 0.1
    , ST_MAKEPOINT(-antimeridian_crossing_longitude, antimeridian_crossing_latitude) as circle_point
  from antimeridian_crossings
order by
    location_id
  , circle_point_id
;

-- Use ST_COLLECT to group the points for each circle together.
-- This should act on the points as they are ordered in the input,
-- and thus create a collection of ordered points
-- around the boundary of our circle
create or replace view circle_points_collected
as
select 
    location_id
  , ST_COLLECT(circle_point) as collected_points
from circle_points_with_antimeridian_crossings 
group by
    location_id
;

create or replace view collected_points_in_batches
as
with crossing_markers as (
  select 
      location_id
    , min(circle_point_id) as minimum_crossing_point_id
    , max(circle_point_id) as maximum_crossing_point_id
  from antimeridian_crossings
  group by location_id
)
select 
    cp.location_id
  , CASE 
      WHEN cm.location_id is null
        THEN 0
      WHEN cp.circle_point_id < cm.minimum_crossing_point_id
        THEN 1
      WHEN cp.circle_point_id < cm.maximum_crossing_point_id
        THEN 2
        ELSE 3
      END as batch_id
  , ST_COLLECT(circle_point) as collected_points_in_batches
from circle_points_with_antimeridian_crossings as cp
  left join crossing_markers as cm
      on cp.location_id = cm.location_id
group by
    cp.location_id
  , batch_id
order by
    cp.location_id
  , batch_id
;


-- Finally, convert the collected points into polygons.
-- We make a line between our collected points and the starting point
-- for the circle (since the circle must start and end at the same location).
-- This is achieved with ST_MAKELINE()

-- We can then make a full circular polygon out of this line with ST_MAKEPOLYGON().
-- The filter for circle_point_id = 0 ensures that the join back to 
-- circle_points only picks up the starting point for the circle.

-- Creating a table instead of a view so that our result is materialised for testing
create or replace table circle_objects_table
as
  select 
      points.location_id
    , ST_MAKELINE(
        collected_points_in_batches
      , circle_point
      ) as circle_line
    , ST_MAKEPOLYGON(circle_line) as circle_poly
  from circle_points as points
    inner join collected_points_in_batches as collected
      on points.location_id = collected.location_id
  where circle_point_id = 0
    and batch_id = 0
  
union all
    
  select 
      points.location_id
    , ST_MAKELINE(
        collected_batch_1.collected_points_in_batches
      , ST_MAKELINE(
          collected_batch_2.collected_points_in_batches
        , ST_MAKELINE(
            collected_batch_3.collected_points_in_batches
          , circle_point
          )
        )
      ) as circle_line
    , ST_MAKEPOLYGON(circle_line) as circle_poly
  from circle_points as points
    inner join collected_points_in_batches as collected_batch_1
      on points.location_id = collected_batch_1.location_id
      and collected_batch_1.batch_id = 1
    inner join collected_points_in_batches as collected_batch_2
      on points.location_id = collected_batch_2.location_id
      and collected_batch_2.batch_id = 2
    inner join collected_points_in_batches as collected_batch_3
      on points.location_id = collected_batch_3.location_id
      and collected_batch_3.batch_id = 3
  where circle_point_id = 0
  
;

select * from circle_objects_table;